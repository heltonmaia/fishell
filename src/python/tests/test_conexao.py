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
