import shlex
from pathlib import Path

import pytest

from fishell.adapters.conexao import Resultado
from fishell.adapters.slurm import (
    LOG_EXTERNO,
    MARCA_LOG,
    SEP_LOGS,
    SEP_SACCT,
    AdaptadorSlurm,
)
from fishell.core.estado import Estado
from fishell.core.modelos import (
    ErroReceita,
    EstadoJob,
    Job,
    Receita,
    SecaoReceita,
    Transferencia,
)

FIXTURES = Path(__file__).parent / "fixtures" / "npad"


def fixture(nome):
    return (FIXTURES / nome).read_text(encoding="utf-8")


def ignorar(_linha):
    pass


class ConexaoFalsa:
    alias = "npad"

    def __init__(self):
        self.comandos = []
        self.sinks = []
        self.rsyncs = []
        self.respostas = []  # fila de Resultado
        self.padrao = Resultado(0, "", "")

    def comando(self, remoto, timeout=60, saida=None):
        self.comandos.append(remoto)
        self.sinks.append(saida)
        return self.respostas.pop(0) if self.respostas else self.padrao

    def resolver(self, caminho):
        return caminho.replace("$USER", "usuario").replace("~", "/home/usuario")

    def rsync(self, origem, destino, t, saida=None):
        self.rsyncs.append((origem, destino, t, saida))
        return Resultado(0, "", "")


def secao(**kw):
    base = dict(
        destino="npad", remoto="/scratch/global/$USER/pose", enviar=(), trazer=(),
        ambiente=None, job=None, submeter=None, comando=None,
        particao="amd-512", log=None,
    )
    base.update(kw)
    return SecaoReceita(**base)


def receita(**kw):
    return Receita(Path("/proj"), "pose", {"npad": secao(**kw)})


@pytest.fixture
def conexao():
    return ConexaoFalsa()


@pytest.fixture
def estado(tmp_path):
    return Estado(tmp_path / "estado.db")


@pytest.fixture
def adaptador(conexao, estado):
    return AdaptadorSlurm("npad", conexao, estado)


def saida_lista(squeue="", sacct="", logs=""):
    return Resultado(0, f"{squeue}\n{SEP_SACCT}\n{sacct}\n{SEP_LOGS}\n{logs}", "")


def test_listar_jobs_usa_um_comando(adaptador, conexao):
    conexao.respostas.append(
        saida_lista(fixture("squeue_array.txt"), fixture("sacct.txt"))
    )
    jobs = adaptador.listar_jobs()
    assert len(conexao.comandos) == 1
    assert conexao.sinks == [None]
    cmd = conexao.comandos[0]
    assert "squeue -h -u" in cmd and "sacct -u" in cmd and SEP_SACCT in cmd
    assert {j.id for j in jobs} >= {"2200000", "2121060"}
    assert all(j.externo for j in jobs)


def test_ultima_linha_vem_do_tail(adaptador, conexao, estado):
    estado.registrar("npad", "2200100", "pose", "infer", "/l/a b/infer_2200100.out", None)
    estado.registrar("npad", "2200000", "pose", "treino", None, None)
    conexao.respostas.append(
        saida_lista(
            fixture("squeue_array.txt"), "",
            f"{MARCA_LOG}2200100\nepoca 3 loss 0.2\n",
        )
    )
    jobs = {j.id: j for j in adaptador.listar_jobs()}
    cmd = conexao.comandos[0]
    assert cmd.count("tail -n 1") == 1
    assert shlex.quote("/l/a b/infer_2200100.out") in cmd and "2>/dev/null" in cmd
    assert jobs["2200100"].ultima_linha == "epoca 3 loss 0.2"
    assert jobs["2200000"].ultima_linha == ""


def test_tail_de_log_com_tarefa_usa_o_mais_recente(adaptador, conexao, estado):
    estado.registrar("npad", "2200000", "pose", "treino", "/l/t_2200000_%a.out", 65)
    conexao.respostas.append(saida_lista(fixture("squeue_array.txt"), "", ""))
    adaptador.listar_jobs()
    assert "ls -t" in conexao.comandos[0]


def test_recursos_filtra_particoes(conexao, estado):
    conexao.respostas.append(Resultado(0, fixture("sinfo.txt"), ""))
    a = AdaptadorSlurm("npad", conexao, estado, particoes=("gpu-4-a100", "amd-512"))
    assert {r.rotulo for r in a.recursos()} == {"gpu-4-a100", "amd-512"}
    assert conexao.comandos[0].startswith("sinfo -h -o")


def test_recursos_sem_filtro(adaptador, conexao):
    conexao.respostas.append(Resultado(0, fixture("sinfo.txt"), ""))
    assert len(adaptador.recursos()) == 10


def test_enviar_faz_mkdir_unico_e_um_rsync_por_transferencia(adaptador, conexao):
    r = receita(enviar=(
        Transferencia("code/", "code/", excluir=(".git",)),
        Transferencia("data/x.csv", "data/x.csv"),
    ))
    adaptador.enviar(r, ignorar)
    assert len(conexao.comandos) == 1
    assert conexao.comandos[0].startswith("mkdir -p ")
    assert "/scratch/global/usuario/pose/code/" in conexao.comandos[0]
    assert "/scratch/global/usuario/pose/data" in conexao.comandos[0]
    assert len(conexao.rsyncs) == 2
    origem, destino, t, saida = conexao.rsyncs[0]
    assert origem == "/proj/code/"
    assert destino == "npad:/scratch/global/usuario/pose/code/"
    assert saida is ignorar


def test_trazer_inverte_origem_e_destino(adaptador, conexao, tmp_path):
    r = Receita(tmp_path, "pose", {"npad": secao(trazer=(Transferencia("out/", "resultados/"),))})
    adaptador.trazer(r, ignorar)
    origem, destino, _, _ = conexao.rsyncs[0]
    assert origem == "npad:/scratch/global/usuario/pose/out/"
    assert destino == f"{tmp_path}/resultados/"
    assert (tmp_path / "resultados").is_dir()


def test_montar_ambiente_em_fluxo(adaptador, conexao):
    conexao.respostas.append(Resultado(3, "", ""))
    codigo = adaptador.montar_ambiente(receita(ambiente="setup.sh"), ignorar)
    assert codigo == 3
    assert conexao.comandos[-1] == "cd /scratch/global/usuario/pose && bash setup.sh"
    assert conexao.sinks[-1] is ignorar


def test_submeter_job_com_array(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "2200000\n", ""))
    id_ = adaptador.submeter(receita(job="train.sbatch"), "gpu-4-a100", "1-65%16", ignorar)
    cmd = conexao.comandos[-1]
    assert "sbatch --parsable -p gpu-4-a100 --array=1-65%16 -o" in cmd and id_ == "2200000"
    assert "logs/fishell_%A_%a.out" in cmd and "mkdir -p /scratch/global/usuario/pose/logs" in cmd
    assert conexao.sinks[-1] is None
    reg = estado.ativos()[0]
    assert reg.array_total == 65
    assert reg.log == "/scratch/global/usuario/pose/logs/fishell_2200000_%a.out"
    assert reg.projeto == "pose" and reg.nome == "train"


def test_submeter_job_simples_expande_o_log(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "77;npad\n", ""))
    assert adaptador.submeter(receita(job="t.sbatch"), None, None, ignorar) == "77"
    assert "-p amd-512" in conexao.comandos[-1] and "--array" not in conexao.comandos[-1]
    assert estado.ativos()[0].log == "/scratch/global/usuario/pose/logs/fishell_77.out"
    assert estado.ativos()[0].array_total is None


def test_submeter_script_le_fishell_job(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "montando\nfishell-job: 2200001\nfim", ""))
    id_ = adaptador.submeter(receita(submeter="go.sh"), None, None, ignorar)
    assert id_ == "2200001"
    assert conexao.comandos[-1] == "cd /scratch/global/usuario/pose && bash go.sh"
    assert conexao.sinks[-1] is ignorar
    assert estado.ativos()[0].job_id == "2200001"


def test_submeter_script_sem_linha_de_id(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "nada util aqui", ""))
    with pytest.raises(ErroReceita, match="nada util aqui"):
        adaptador.submeter(receita(submeter="go.sh"), None, None, ignorar)
    assert estado.ativos() == []


def test_submeter_cita_caminhos(adaptador, conexao):
    conexao.respostas.append(Resultado(0, "5", ""))
    r = receita(remoto="/scratch/global/usuario/meu projeto", job="code/run's.sbatch")
    adaptador.submeter(r, "amd-512", None, ignorar)
    cmd = conexao.comandos[-1]
    assert shlex.quote("/scratch/global/usuario/meu projeto") in cmd
    assert shlex.quote("code/run's.sbatch") in cmd


def test_receita_sem_secao_do_destino(adaptador):
    r = Receita(Path("/proj"), "pose", {})
    with pytest.raises(ErroReceita, match="npad"):
        adaptador.submeter(r, None, None, ignorar)


def test_cancelar(adaptador, conexao):
    adaptador.cancelar("2200000")
    assert conexao.comandos[-1] == "scancel 2200000"


def test_log_externo(adaptador):
    j = Job("npad", "1", "x", EstadoJob.RODANDO, externo=True)
    assert adaptador.log(j) == [LOG_EXTERNO]


def test_log_simples(adaptador, conexao):
    conexao.respostas.append(Resultado(0, "a\nb\n", ""))
    j = Job("npad", "9", "x", EstadoJob.RODANDO, log="/l/a b.out")
    assert adaptador.log(j, 10) == ["a", "b"]
    assert conexao.comandos[-1] == f"tail -n 10 -- {shlex.quote('/l/a b.out')}"


def test_log_de_array_usa_a_tarefa_rodando_mais_recente(adaptador, conexao):
    conexao.respostas.append(
        Resultado(0, f"{fixture('squeue_array.txt')}\n{SEP_SACCT}\n", "")
    )
    conexao.respostas.append(Resultado(0, "linha", ""))
    j = Job("npad", "2200000", "treino", EstadoJob.RODANDO, log="/l/t_2200000_%a.out")
    assert adaptador.log(j) == ["linha"]
    assert conexao.comandos[-1].endswith("/l/t_2200000_47.out")


def test_log_de_array_sem_rodando_usa_a_ultima_concluida(adaptador, conexao):
    sacct = "5_1|x|COMPLETED|0:0|00:01:00\n5_3|x|COMPLETED|0:0|00:01:00\n5_2|x|FAILED|1:0|00:01:00"
    conexao.respostas.append(Resultado(0, f"\n{SEP_SACCT}\n{sacct}", ""))
    conexao.respostas.append(Resultado(0, "z", ""))
    j = Job("npad", "5", "x", EstadoJob.OK, log="/l/x_5_%a.out")
    adaptador.log(j)
    assert conexao.comandos[-1].endswith("/l/x_5_3.out")


def test_nenhum_comando_apaga(adaptador, conexao, estado, tmp_path):
    r = Receita(tmp_path, "pose", {"npad": secao(
        enviar=(Transferencia("a/", "a/"),), trazer=(Transferencia("o/", "o/"),),
        ambiente="s.sh", job="j.sbatch",
    )})
    conexao.respostas = [
        Resultado(0, "", ""), Resultado(0, "", ""),
        Resultado(0, "10", ""), Resultado(0, "", ""),
        saida_lista(fixture("squeue_array.txt"), fixture("sacct.txt")),
        Resultado(0, fixture("sinfo.txt"), ""),
    ]
    adaptador.enviar(r, ignorar)
    adaptador.trazer(r, ignorar)
    adaptador.montar_ambiente(r, ignorar)
    adaptador.submeter(r, None, "1-3", ignorar)
    adaptador.cancelar("10")
    adaptador.listar_jobs()
    adaptador.recursos()
    adaptador.log(Job("npad", "10", "j", EstadoJob.OK, log="/l/x.out"))
    textos = [*conexao.comandos] + [
        f"{o} {d} {' '.join(t.incluir + t.excluir)}" for o, d, t, _ in conexao.rsyncs
    ]
    for c in textos:
        assert "rm " not in c and "--delete" not in c and "--remove-source-files" not in c


def test_conclusao_atualiza_estado(adaptador, conexao, estado):
    estado.registrar("npad", "2121060", "pose", "desenhos", "/l/x.out", None)
    conexao.respostas = [
        saida_lista("", fixture("sacct.txt")),
        saida_lista("", fixture("sacct.txt")),
    ]
    jobs = {j.id: j for j in adaptador.listar_jobs()}
    assert jobs["2121060"].estado == EstadoJob.OK
    assert estado.ativos() == []
    assert estado.atualizar("npad", "2121060", EstadoJob.OK) is False
