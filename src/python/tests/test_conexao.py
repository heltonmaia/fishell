from datetime import datetime, timedelta

import pytest

from fishell.adapters.base import ErroAutenticacao, Indisponivel
from fishell.adapters.conexao import Conexao, Resultado
from fishell.core.modelos import Transferencia

T0 = datetime(2026, 10, 31, 12, 0)


class Relogio:
    def __init__(self):
        self.t = T0

    def __call__(self):
        return self.t

    def avancar(self, **kw):
        self.t += timedelta(**kw)


def montar(tmp_path, respostas=None):
    chamadas = []
    fila = list(respostas or [])

    def executar(argv, timeout, saida):
        chamadas.append(argv)
        return fila.pop(0) if fila else Resultado(0, "", "")

    relogio = Relogio()
    c = Conexao("npad", tmp_path / "ctl", executar, relogio)
    return c, chamadas, relogio


def test_toda_chamada_usa_a_mesma_conexao(tmp_path):
    c, chamadas, _ = montar(tmp_path)
    c.comando("squeue")
    c.rsync("a/", "npad:b/", Transferencia("a/", "b/"))
    c.fechar()
    assert len(chamadas) == 3
    for argv in chamadas:
        juntos = " ".join(argv)
        assert "ControlMaster=auto" in juntos
        assert f"ControlPath={tmp_path / 'ctl'}/%C" in juntos
        assert "ControlPersist=600" in juntos
    assert chamadas[0] == ["ssh", *c.opcoes_ssh(), "npad", "squeue"]
    assert (tmp_path / "ctl").stat().st_mode & 0o777 == 0o700


def test_rsync_nunca_apaga(tmp_path):
    c, chamadas, _ = montar(tmp_path)
    t = Transferencia("a/", "b/", incluir=("*.py",), excluir=("*",))
    c.rsync("a/", "npad:b/", t)
    c.rsync("npad:b/", "a/", Transferencia("b/", "a/"))
    assert len(chamadas) == 2
    for argv in chamadas:
        assert argv[:2] == ["rsync", "-a"]
        assert not {"--delete", "--remove-source-files"} & set(argv)
        assert not any(a.startswith("--delete") for a in argv)
    a = chamadas[0]
    assert a[-2:] == ["a/", "npad:b/"]
    assert a.index("--include=*.py") < a.index("--exclude=*")
    assert a[a.index("-e") + 1].startswith("ssh -o ControlMaster=auto")


def test_recusa_bloqueia_por_30_min(tmp_path):
    c, chamadas, relogio = montar(
        tmp_path, [Resultado(255, "", "Connection closed by remote host")]
    )
    with pytest.raises(Indisponivel) as e:
        c.comando("squeue")
    assert e.value.ate == T0 + timedelta(minutes=30)
    relogio.avancar(minutes=29)
    with pytest.raises(Indisponivel):
        c.comando("squeue")
    with pytest.raises(Indisponivel):
        c.rsync("a/", "npad:b/", Transferencia("a/", "b/"))
    assert len(chamadas) == 1
    relogio.avancar(minutes=2)
    assert c.comando("squeue").codigo == 0


def test_recusa_no_rsync_tambem_bloqueia(tmp_path):
    c, chamadas, _ = montar(tmp_path, [Resultado(255, "", "kex_exchange_identification")])
    with pytest.raises(Indisponivel):
        c.rsync("a/", "npad:b/", Transferencia("a/", "b/"))
    with pytest.raises(Indisponivel):
        c.comando("x")
    assert len(chamadas) == 1


def test_permission_denied_e_autenticacao(tmp_path):
    c, chamadas, _ = montar(tmp_path, [Resultado(255, "", "Permission denied (publickey)")])
    with pytest.raises(ErroAutenticacao):
        c.comando("squeue")
    c.comando("squeue")  # sem bloqueio
    assert len(chamadas) == 2


def test_resolver_expande_uma_vez(tmp_path):
    c, chamadas, _ = montar(tmp_path, [Resultado(0, "/scratch/global/usuario/pose", "")])
    assert c.resolver("/scratch/global/$USER/pose") == "/scratch/global/usuario/pose"
    c.resolver("/scratch/global/$USER/pose")
    assert len(chamadas) == 1
    assert chamadas[0][-1] == 'printf %s "/scratch/global/$USER/pose"'


def test_resolver_til_e_escapes(tmp_path):
    c, chamadas, _ = montar(tmp_path, [Resultado(0, "/h/x", ""), Resultado(0, "z", "")])
    c.resolver("~/x")
    assert chamadas[0][-1] == 'printf %s "$HOME/x"'
    c.resolver('a"b`c\\d$(rm)')
    assert chamadas[1][-1] == 'printf %s "a\\"b\\`c\\\\d\\$(rm)"'


# --- rodada de correcoes 1 ---
import subprocess
import threading
import time

from fishell.adapters.conexao import executar_subprocess


def montar_bloqueante(tmp_path, mux_primeira=False):
    soltar = threading.Event()
    rsync_iniciou = threading.Event()
    chamadas = []
    estado = {"mux": mux_primeira, "timeouts": []}

    def executar(argv, timeout, saida):
        chamadas.append(argv)
        estado["timeouts"].append((argv[0], timeout))
        if argv[0] == "rsync":
            rsync_iniciou.set()
            soltar.wait(5)
            return Resultado(0, "", "")
        if estado["mux"]:
            estado["mux"] = False
            return Resultado(255, "", "mux_client_request_session: session request failed")
        return Resultado(0, "ok", "")

    c = Conexao("npad", tmp_path / "ctl", executar, Relogio())
    return c, chamadas, soltar, rsync_iniciou, estado


def em_thread(fn):
    feito = threading.Event()
    res = {}

    def alvo():
        try:
            res["v"] = fn()
        except Exception as e:  # noqa: BLE001
            res["e"] = e
        feito.set()

    threading.Thread(target=alvo, daemon=True).start()
    return feito, res


def test_consulta_curta_nao_espera_rsync_longo(tmp_path):
    c, _, soltar, iniciou, _ = montar_bloqueante(tmp_path)
    longo, _ = em_thread(lambda: c.rsync("a/", "npad:b/", Transferencia("a/", "b/")))
    assert iniciou.wait(2)
    curto, res = em_thread(lambda: c.comando("squeue"))
    assert curto.wait(2), "consulta curta ficou presa atras do rsync"
    assert not longo.is_set()
    soltar.set()
    assert longo.wait(2)


def test_recusa_de_canal_extra_vira_modo_serial(tmp_path):
    c, chamadas, soltar, iniciou, _ = montar_bloqueante(tmp_path, mux_primeira=True)
    r = c.comando("squeue")
    assert r.codigo == 0
    assert len(chamadas) == 2  # refeita uma vez
    assert c._bloqueado_ate is None
    longo, _ = em_thread(lambda: c.rsync("a/", "npad:b/", Transferencia("a/", "b/")))
    assert iniciou.wait(2)
    curto, _ = em_thread(lambda: c.comando("squeue"))
    time.sleep(0.3)
    assert not curto.is_set(), "em modo serial a consulta deve esperar o rsync"
    soltar.set()
    assert longo.wait(2) and curto.wait(2)


def test_rsync_e_comando_com_saida_sem_timeout(tmp_path):
    c, _, soltar, _, estado = montar_bloqueante(tmp_path)
    soltar.set()
    c.rsync("a/", "npad:b/", Transferencia("a/", "b/"))
    c.comando("x", saida=lambda l: None)
    c.comando("y")
    assert estado["timeouts"][0] == ("rsync", None)
    assert estado["timeouts"][1][1] is None
    assert estado["timeouts"][2][1] == 60


def test_resolver_falha_nao_e_cacheado(tmp_path):
    c, chamadas, _ = montar(
        tmp_path,
        [Resultado(1, "", "boom"), Resultado(0, "   ", ""), Resultado(0, "/h/x", "")],
    )
    with pytest.raises(RuntimeError, match="boom"):
        c.resolver("~/x")
    with pytest.raises(RuntimeError):
        c.resolver("~/x")
    assert c.resolver("~/x") == "/h/x"
    assert len(chamadas) == 3


def test_saida_que_levanta_mata_o_filho(tmp_path):
    def ruim(linha):
        raise ValueError("app fechou")

    t0 = time.monotonic()
    with pytest.raises(ValueError):
        executar_subprocess(["sh", "-c", "echo a; sleep 5.123; echo b"], None, ruim)
    assert time.monotonic() - t0 < 3
    time.sleep(0.2)
    vivo = subprocess.run(["pgrep", "-f", "sleep 5.123"], capture_output=True)
    assert vivo.stdout == b""
