import os
import shutil
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from fishell.adapters.conexao import Resultado
from fishell.adapters.local import AdaptadorLocal
from fishell.core.estado import Estado
from fishell.core.modelos import ErroReceita, EstadoJob, Receita, SecaoReceita

FIXTURES = Path(__file__).parent / "fixtures" / "local"


def ignorar(_linha):
    pass


def secao(**kw):
    base = dict(
        destino="local", remoto=None, enviar=(), trazer=(), ambiente=None,
        job=None, submeter=None, comando=None, particao=None, log=None,
    )
    base.update(kw)
    return SecaoReceita(**base)


def receita(raiz="/tmp/meu proj", **kw):
    return Receita(Path(raiz), "proj", {"local": secao(**kw)})


class Falso:
    def __init__(self, respostas=None):
        self.chamadas = []
        self.sinks = []
        self.respostas = respostas or {}

    def __call__(self, argv, timeout, saida):
        self.chamadas.append(argv)
        self.sinks.append((timeout, saida))
        for chave, r in self.respostas.items():
            if chave in argv:
                return r
        return Resultado(0, "", "")


@pytest.fixture
def estado(tmp_path):
    return Estado(tmp_path / "estado.db")


def novo(estado, tmp_path, executar, **kw):
    return AdaptadorLocal(estado, tmp_path / "jobs", executar, **kw)


def espera_ate(cond, tempo=10):
    fim = time.time() + tempo
    while time.time() < fim:
        if cond():
            return
        time.sleep(0.1)
    raise AssertionError("tempo esgotado")


def test_recursos_da_gpu(estado, tmp_path):
    texto = (FIXTURES / "nvidia_smi.txt").read_text()
    f = Falso({"nvidia-smi": Resultado(0, texto, "")})
    r = novo(estado, tmp_path, f).recursos()
    assert len(r) == 1
    assert r[0].rotulo == "RTX 5060 Ti"
    assert r[0].texto == "61% 9/16G"
    assert f.chamadas[0][0] == "nvidia-smi"


def test_sem_nvidia_smi(estado, tmp_path):
    f = Falso({"nvidia-smi": Resultado(127, "", "não achei")})
    assert novo(estado, tmp_path, f).recursos() == []


def test_comando_com_aspas(estado, tmp_path):
    f = Falso()
    a = novo(estado, tmp_path, f)
    id_ = a.submeter(receita(comando='python train.py --nome "a b"'), None, None, ignorar)
    argv = f.chamadas[-1]
    assert argv[:5] == ["tmux", "new-session", "-d", "-s", f"fishell-{id_}"]
    assert argv[5:7] == ["-c", "/tmp/meu proj"]
    assert 'python train.py --nome "a b"' in argv[-1]
    assert argv[-1].startswith("bash -c ")
    assert id_.startswith("l")
    assert [r.job_id for r in estado.ativos("local")] == [id_]


def test_socket_do_tmux(estado, tmp_path):
    f = Falso()
    a = novo(estado, tmp_path, f, tmux_socket="sock")
    a.submeter(receita(comando="true"), None, None, ignorar)
    assert f.chamadas[-1][:3] == ["tmux", "-L", "sock"]


def test_id_repetido_ganha_sufixo(estado, tmp_path):
    a = novo(estado, tmp_path, Falso())
    ids = {a.submeter(receita(comando="true"), None, None, ignorar) for _ in range(3)}
    assert len(ids) == 3


def test_secao_ou_comando_ausente(estado, tmp_path):
    a = novo(estado, tmp_path, Falso())
    with pytest.raises(ErroReceita, match="comando"):
        a.submeter(receita(), None, None, ignorar)
    with pytest.raises(ErroReceita, match="local"):
        a.submeter(Receita(Path("/x"), "p", {}), None, None, ignorar)
    with pytest.raises(ErroReceita, match="ambiente"):
        a.montar_ambiente(receita(), ignorar)


def test_montar_ambiente(estado, tmp_path):
    f = Falso({"bash": Resultado(3, "", "")})
    a = novo(estado, tmp_path, f)
    codigo = a.montar_ambiente(receita(ambiente="env setup.sh"), ignorar)
    assert codigo == 3
    assert f.chamadas[0] == ["bash", "-c", "cd '/tmp/meu proj' && bash 'env setup.sh'"]
    assert f.sinks[0] == (None, ignorar)


def test_sessao_sumida_fica_desconhecido(estado, tmp_path):
    f = Falso({"list-sessions": Resultado(1, "", "no server running")})
    a = novo(estado, tmp_path, f)
    estado.registrar("local", "l20260101-000000", "proj", "proj", None, None)
    j = a.listar_jobs()[0]
    assert j.estado == EstadoJob.FALHOU
    assert j.motivo == "sessão sumiu"
    assert estado.ativos("local") == []
    assert estado.recentes("local", datetime.min)[0].estado == EstadoJob.FALHOU


def test_exit_file_decide(estado, tmp_path):
    f = Falso({"list-sessions": Resultado(0, "fishell-l1\nfishell-l2\n", "")})
    a = novo(estado, tmp_path, f)
    for i in ("l1", "l2", "l3"):
        estado.registrar("local", i, "proj", "proj", str(a.dir_jobs / f"{i}.log"), None)
    (a.dir_jobs / "l1.exit").write_text("0\n")
    (a.dir_jobs / "l3.exit").write_text("2\n")
    (a.dir_jobs / "l2.log").write_text("a\nb\n\n")
    por_id = {j.id: j for j in a.listar_jobs()}
    assert por_id["l1"].estado == EstadoJob.OK
    assert por_id["l2"].estado == EstadoJob.RODANDO
    assert por_id["l2"].ultima_linha == "b"
    assert por_id["l3"].estado == EstadoJob.FALHOU
    assert a.log(por_id["l2"], 2) == ["b", ""]


def test_cancelar(estado, tmp_path):
    f = Falso()
    a = novo(estado, tmp_path, f)
    estado.registrar("local", "l9", "proj", "proj", None, None)
    a.cancelar("l9")
    assert f.chamadas[0] == ["tmux", "kill-session", "-t", "fishell-l9"]
    assert estado.recentes("local", datetime.min)[0].estado == EstadoJob.CANCELADO


def reg_estado(estado, id_):
    return [r for r in estado.recentes("local", datetime.min) if r.job_id == id_][0].estado


def test_terminal_nao_e_reescrito(estado, tmp_path):
    f = Falso({"list-sessions": Resultado(1, "", "no server running on /tmp/x")})
    a = novo(estado, tmp_path, f)
    estado.registrar("local", "l1", "proj", "proj", None, None)
    (a.dir_jobs / "l1.exit").write_text("0\n")
    chamadas = []
    original = estado.atualizar
    estado.atualizar = lambda *x: chamadas.append(x) or original(*x)
    assert a.listar_jobs()[0].estado == EstadoJob.OK
    assert a.listar_jobs()[0].estado == EstadoJob.OK
    assert len(chamadas) == 1
    (a.dir_jobs / "l1.exit").unlink()
    assert a.listar_jobs()[0].estado == EstadoJob.OK
    assert reg_estado(estado, "l1") == EstadoJob.OK
    assert len(chamadas) == 1


def test_falha_do_tmux_nao_escreve(estado, tmp_path):
    f = Falso({"list-sessions": Resultado(1, "", "protocol version mismatch")})
    a = novo(estado, tmp_path, f)
    estado.registrar("local", "l1", "proj", "proj", None, None)
    estado.atualizar("local", "l1", EstadoJob.RODANDO)
    assert a.listar_jobs()[0].estado == EstadoJob.RODANDO
    assert reg_estado(estado, "l1") == EstadoJob.RODANDO


def test_cancelado_aparece_na_listagem(estado, tmp_path):
    f = Falso({"list-sessions": Resultado(1, "", "no server running")})
    a = novo(estado, tmp_path, f)
    estado.registrar("local", "l9", "proj", "proj", None, None)
    a.cancelar("l9")
    assert a.listar_jobs()[0].estado == EstadoJob.CANCELADO


def test_job_antigo_ainda_rodando_aparece(estado, tmp_path):
    f = Falso({"list-sessions": Resultado(0, "fishell-l1\n", "")})
    a = novo(estado, tmp_path, f)
    estado.registrar("local", "l1", "proj", "proj", None, None)
    antigo = (datetime.now() - timedelta(hours=30)).isoformat()
    with sqlite3.connect(estado.arquivo) as con:
        con.execute("UPDATE jobs SET inicio = ?", (antigo,))
    jobs = a.listar_jobs()
    assert [j.id for j in jobs] == ["l1"]
    assert jobs[0].estado == EstadoJob.RODANDO


@pytest.mark.skipif(shutil.which("tmux") is None, reason="sem tmux")
def test_job_real_no_tmux(tmp_path):
    from fishell.adapters.conexao import executar_subprocess

    sock = f"fishell-teste-{os.getpid()}"
    a = AdaptadorLocal(Estado(tmp_path / "e.db"), tmp_path / "jobs", tmux_socket=sock)
    try:
        r = lambda c: receita(raiz=str(tmp_path), comando=c)
        a.submeter(r("echo oi"), None, None, ignorar)
        espera_ate(lambda: a.listar_jobs()[0].estado == EstadoJob.OK)
        assert a.listar_jobs()[0].ultima_linha == "oi"
        a.submeter(r("exit 3"), None, None, ignorar)
        a.submeter(r("echo ok # comentario"), None, None, ignorar)
        espera_ate(lambda: all(j.estado in (EstadoJob.OK, EstadoJob.FALHOU) for j in a.listar_jobs()) and len(a.listar_jobs()) == 3)
        por_cmd = {j.id: j for j in a.listar_jobs()}
        estados = sorted(j.estado.value for j in por_cmd.values())
        assert estados == ["falhou", "ok", "ok"]
    finally:
        executar_subprocess(["tmux", "-L", sock, "kill-server"], 10, None)
