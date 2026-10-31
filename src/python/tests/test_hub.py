import threading
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from fishell.adapters.base import ErroAutenticacao, Indisponivel
from fishell.adapters.local import AdaptadorLocal
from fishell.adapters.slurm import AdaptadorSlurm
from fishell.core.estado import Estado
from fishell.core.hub import Hub
from fishell.core.modelos import EstadoJob, Job, Receita, Recurso
from fishell.core.montagem import montar_hub
from tests.fakes import AdaptadorFalso

T0 = datetime(2026, 10, 31, 10, 0)


def job(destino, id_, estado=EstadoJob.RODANDO):
    return Job(destino=destino, id=id_, nome="n", estado=estado)


class Relogio:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def hub(tmp_path, relogio=None, receitas=None, vigia=None, **adaptadores):
    return Hub(
        adaptadores,
        Estado(tmp_path / "e.db"),
        receitas if receitas is not None else [Receita(tmp_path, "proj", {})],
        relogio=relogio or Relogio(),
        iniciar_vigia=vigia or (lambda: None),
    )


def ignorar(_):
    pass


def test_respeita_intervalos(tmp_path):
    r = Relogio()
    local = AdaptadorFalso("local", intervalo=3)
    npad = AdaptadorFalso("npad", intervalo=60)
    h = hub(tmp_path, r, local=local, npad=npad)
    h.atualizar()
    r.t = 5
    h.atualizar()
    assert len(local.chamadas) == 4 and len(npad.chamadas) == 2
    r.t = 60
    h.atualizar()
    assert len(npad.chamadas) == 4


def test_adaptador_com_erro_nao_derruba_os_outros(tmp_path):
    j1 = job("local", "1")
    npad = AdaptadorFalso("npad", erro=Indisponivel(ate=T0 + timedelta(minutes=30)))
    v = hub(tmp_path, npad=npad, local=AdaptadorFalso("local", jobs=[j1])).atualizar(forcar=True)
    assert v.jobs == [j1]
    assert v.avisos["npad"] == "indisponível até 10:30"


def test_erro_generico_vira_aviso(tmp_path):
    v = hub(tmp_path, a=AdaptadorFalso("a", erro=RuntimeError("quebrou"))).atualizar()
    assert "quebrou" in v.avisos["a"]


def test_destino_com_erro_nao_contribui(tmp_path):
    r = Relogio()
    a = AdaptadorFalso("a", jobs=[job("a", "1")], recursos=[Recurso("x")])
    h = hub(tmp_path, r, a=a)
    assert h.atualizar().jobs
    a.erro = RuntimeError("x")
    v = h.atualizar(forcar=True)
    assert v.jobs == [] and v.recursos["a"] == [] and "a" in v.avisos
    a.erro = None
    v = h.atualizar(forcar=True)
    assert v.jobs and "a" not in v.avisos


def test_ordem_ativos_primeiro(tmp_path):
    jobs = [job("b", "1", EstadoJob.OK), job("b", "2"), job("a", "9", EstadoJob.FALHOU), job("a", "3")]
    v = hub(tmp_path, a=AdaptadorFalso("a", jobs=jobs[2:]), b=AdaptadorFalso("b", jobs=jobs[:2])).atualizar()
    assert [(j.destino, j.id) for j in v.jobs] == [("a", "3"), ("b", "2"), ("a", "9"), ("b", "1")]


def test_erro_de_autenticacao_para_o_polling_ate_forcar(tmp_path):
    r = Relogio()
    a = AdaptadorFalso("a", erro=ErroAutenticacao(), intervalo=1)
    h = hub(tmp_path, r, a=a)
    v = h.atualizar()
    assert v.avisos["a"].startswith("sem acesso")
    n = len(a.chamadas)
    r.t = 100
    v = h.atualizar()
    assert len(a.chamadas) == n and v.avisos["a"].startswith("sem acesso")
    h.atualizar(forcar=True)
    assert len(a.chamadas) > n


def test_concorrencia_pula_destino_em_andamento(tmp_path):
    entrou, soltar = threading.Event(), threading.Event()

    class Lento(AdaptadorFalso):
        def listar_jobs(self):
            entrou.set()
            assert soltar.wait(5)
            return super().listar_jobs()

    lento = Lento("lento", jobs=[job("lento", "1")])
    h = hub(tmp_path, lento=lento)
    t = threading.Thread(target=h.atualizar)
    t.start()
    assert entrou.wait(5)
    v = h.atualizar(forcar=True)  # não bloqueia nem inicia segunda consulta
    assert v.jobs == []
    soltar.set()
    t.join(5)
    assert [c for c, _ in lento.chamadas].count("listar_jobs") == 1
    assert len(h.atualizar().jobs) == 1


def test_acao_deixa_destino_vencido(tmp_path):
    r = Relogio()
    a = AdaptadorFalso("a", intervalo=60)
    h = hub(tmp_path, r, a=a)
    h.atualizar()
    h.atualizar()
    assert [c for c, _ in a.chamadas].count("listar_jobs") == 1
    h.cancelar("a", "1")
    h.atualizar()
    assert [c for c, _ in a.chamadas].count("listar_jobs") == 2
    h.enviar("proj", "a", ignorar)
    h.atualizar()
    assert [c for c, _ in a.chamadas].count("listar_jobs") == 3


def test_submeter_envia_antes_e_inicia_vigia(tmp_path):
    chamadas = []
    a = AdaptadorFalso("a", id_submetido="42")
    h = hub(tmp_path, vigia=lambda: chamadas.append("vigia"), a=a)
    assert h.submeter("proj", "a", saida=ignorar) == "42"
    assert [c for c, _ in a.chamadas] == ["enviar", "submeter"]
    assert chamadas == ["vigia"]


def test_submeter_sem_enviar_antes(tmp_path):
    a = AdaptadorFalso("a")
    h = hub(tmp_path, a=a)
    h.submeter("proj", "a", "gpu", "1-4", False, saida=ignorar)
    assert [c for c, _ in a.chamadas] == ["submeter"]
    assert a.chamadas[0][1][1:3] == ("gpu", "1-4")


def test_acao_sem_capacidade(tmp_path):
    h = hub(tmp_path, local=AdaptadorFalso("local", capacidades=frozenset({"submeter"})))
    with pytest.raises(ValueError, match="trazer"):
        h.trazer("proj", "local", ignorar)


def test_receita_desconhecida(tmp_path):
    h = hub(tmp_path, a=AdaptadorFalso("a"))
    with pytest.raises(ValueError, match="nada"):
        h.receita("nada")


def test_receita_com_erro_bloqueia_acoes(tmp_path):
    h = hub(tmp_path, receitas=[Receita(tmp_path, "proj", {}, erro="receita quebrada")], a=AdaptadorFalso("a"))
    with pytest.raises(ValueError, match="receita quebrada"):
        h.enviar("proj", "a", ignorar)


def test_log_e_destino_desconhecido(tmp_path):
    h = hub(tmp_path, a=AdaptadorFalso("a", linhas_log=["x"]))
    assert h.log(job("a", "1")) == ["x"]
    with pytest.raises(ValueError):
        h.cancelar("zzz", "1")


def test_montar_hub(tmp_path):
    cfg, est, cwd = tmp_path / "cfg", tmp_path / "est", tmp_path / "cwd"
    for d in (cfg, cwd):
        d.mkdir()
    (cfg / "destinos.toml").write_text(
        '[[destino]]\nnome = "local"\ntipo = "local"\n'
        '[[destino]]\nnome = "npad"\ntipo = "slurm"\nssh = "meunpad"\nparticoes = ["gpu"]\n',
        encoding="utf-8",
    )
    h = montar_hub(cfg, est, cwd)
    assert isinstance(h.adaptadores["local"], AdaptadorLocal)
    npad = h.adaptadores["npad"]
    assert isinstance(npad, AdaptadorSlurm)
    assert npad.conexao.alias == "meunpad" and npad.conexao.dir_ctl == est / "ctl"
    assert npad.particoes == ("gpu",)
    assert (est / "estado.db").exists() and h.receitas == []


def test_montar_hub_vigia_padrao_e_dado(tmp_path):
    h = montar_hub(tmp_path / "c", tmp_path / "e", tmp_path)
    h._iniciar_vigia()
    chamadas = []
    h = montar_hub(tmp_path / "c", tmp_path / "e", tmp_path, lambda: chamadas.append(1))
    h._iniciar_vigia()
    assert chamadas == [1]


def test_acao_durante_consulta_em_andamento_mantem_destino_vencido(tmp_path):
    entrou, soltar = threading.Event(), threading.Event()

    class Lento(AdaptadorFalso):
        def listar_jobs(self):
            if not entrou.is_set():
                entrou.set()
                assert soltar.wait(5)
            return super().listar_jobs()

    lento = Lento("lento", intervalo=60)
    h = hub(tmp_path, lento=lento)
    t = threading.Thread(target=h.atualizar)
    t.start()
    assert entrou.wait(5)
    h.cancelar("lento", "1")
    soltar.set()
    t.join(5)
    h.atualizar()
    assert [c for c, _ in lento.chamadas].count("listar_jobs") == 2


def test_visao_expoe_indisponivel_e_sem_acesso(tmp_path):
    ate = T0 + timedelta(minutes=30)
    h = hub(
        tmp_path,
        npad=AdaptadorFalso("npad", erro=Indisponivel(ate)),
        outro=AdaptadorFalso("outro", erro=ErroAutenticacao()),
        ok=AdaptadorFalso("ok"),
    )
    v = h.atualizar()
    assert v.indisponivel_ate == {"npad": ate}
    assert v.sem_acesso == frozenset({"outro"})


# --- F3: vigia reiniciado quando preciso ------------------------------
def test_garantir_vigia_so_quando_ha_o_que_vigiar(tmp_path):
    chamadas = []
    h = hub(tmp_path, vigia=lambda: chamadas.append(1), a=AdaptadorFalso("a"))
    assert h.garantir_vigia_se_preciso() is None
    assert chamadas == []
    h.estado.registrar("a", "1", "proj", "n", None, None)
    assert h.garantir_vigia_se_preciso() is None
    assert chamadas == [1]
    h.estado.atualizar("a", "1", EstadoJob.OK)  # terminou, aviso pendente
    h.garantir_vigia_se_preciso()
    assert chamadas == [1, 1]
    h.estado.marcar_notificado("a", "1")
    h.garantir_vigia_se_preciso()
    assert chamadas == [1, 1]


def test_garantir_vigia_engole_e_devolve_oserror(tmp_path):
    def quebra():
        raise PermissionError("sem permissão em vigia.lock")

    h = hub(tmp_path, vigia=quebra, a=AdaptadorFalso("a"))
    h.estado.registrar("a", "1", "proj", "n", None, None)
    erro = h.garantir_vigia_se_preciso()
    assert isinstance(erro, OSError) and "vigia.lock" in str(erro)


def test_submeter_com_vigia_quebrado_devolve_o_id(tmp_path):
    def quebra():
        raise OSError("python sumiu")

    linhas = []
    h = hub(tmp_path, vigia=quebra, a=AdaptadorFalso("a", id_submetido="42"))
    assert h.submeter("proj", "a", saida=linhas.append) == "42"
    assert any("python sumiu" in l for l in linhas)
