from datetime import datetime, timedelta

from fishell.core.estado import Estado
from fishell.core.modelos import EstadoJob


def test_atualizar_avisa_uma_vez(tmp_path):
    e = Estado(tmp_path / "e.db")
    e.registrar("npad", "123", "pose", "kp", None, 65)
    assert e.atualizar("npad", "123", EstadoJob.OK) is True
    assert e.atualizar("npad", "123", EstadoJob.OK) is False
    assert e.ativos() == []


def test_transicao_nao_terminal_persiste(tmp_path):
    e = Estado(tmp_path / "sub" / "e.db")
    e.registrar("npad", "1", "p", "n", "/log", None)
    assert e.atualizar("npad", "1", EstadoJob.RODANDO) is False
    r = e.ativos("npad")[0]
    assert r.estado == EstadoJob.RODANDO
    assert (r.log, r.array_total, r.notificado) == ("/log", None, False)
    assert e.ativos("outro") == []


def test_persiste_entre_instancias_e_notificado(tmp_path):
    arq = tmp_path / "e.db"
    Estado(arq).registrar("npad", "1", "p", "n", None, None)
    e = Estado(arq)
    assert e.atualizar("npad", "1", EstadoJob.FALHOU) is True
    e.marcar_notificado("npad", "1")
    r = e.recentes("npad", datetime.now() - timedelta(hours=1))
    assert len(r) == 1 and r[0].notificado and r[0].estado == EstadoJob.FALHOU
    assert e.recentes("npad", datetime.now() + timedelta(hours=1)) == []


def test_registrar_repetido_nao_reinicia(tmp_path):
    e = Estado(tmp_path / "e.db")
    e.registrar("npad", "1", "p", "n", None, None)
    e.atualizar("npad", "1", EstadoJob.OK)
    e.registrar("npad", "1", "p", "n", None, None)
    assert e.ativos() == []
    assert e.atualizar("npad", "1", EstadoJob.OK) is False


def test_terminal_nao_e_sobrescrito(tmp_path):
    e = Estado(tmp_path / "e.db")
    e.registrar("npad", "1", "p", "n", None, None)
    assert e.atualizar("npad", "1", EstadoJob.OK) is True
    assert e.atualizar("npad", "1", EstadoJob.RODANDO) is False
    assert e.atualizar("npad", "1", EstadoJob.OK) is False
    assert e.ativos() == []
    assert e.recentes("npad", datetime.now() - timedelta(hours=1))[0].estado == EstadoJob.OK


def test_corrida_entre_instancias_so_uma_avisa(tmp_path):
    from concurrent.futures import ThreadPoolExecutor

    arq = tmp_path / "e.db"
    Estado(arq).registrar("npad", "1", "p", "n", None, None)
    estados = [Estado(arq) for _ in range(8)]
    with ThreadPoolExecutor(8) as ex:
        res = list(ex.map(lambda x: x.atualizar("npad", "1", EstadoJob.OK), estados))
    assert res.count(True) == 1
