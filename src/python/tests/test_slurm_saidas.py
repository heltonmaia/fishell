from pathlib import Path

import pytest

from fishell.adapters.slurm_saidas import (
    LinhaSacct,
    LinhaSqueue,
    agrupar,
    estado_slurm,
    ler_sacct,
    ler_sinfo,
    ler_squeue,
)
from fishell.core.estado import RegistroJob
from fishell.core.modelos import EstadoJob
from datetime import datetime

FIXTURES = Path(__file__).parent / "fixtures" / "npad"


def fixture(nome: str) -> str:
    return (FIXTURES / nome).read_text(encoding="utf-8")


def registro(job_id="2200000", array_total=None, nome="treino", projeto="pose", log="/l/%A_%a.out"):
    return RegistroJob("npad", job_id, projeto, nome, log, array_total,
                       datetime(2026, 10, 31), EstadoJob.FILA, False)


def historico_com_44_ok():
    return [LinhaSacct(f"2200000_{i}", "treino", "COMPLETED", "0:0", "00:01:00") for i in range(1, 45)]


def rodando(job, tarefas):
    return [LinhaSqueue(f"{job}_{i}", "big", "RUNNING", "1:00", "amd-512", "node01") for i in tarefas]


def test_sinfo_real():
    r = {x.rotulo: x for x in ler_sinfo(fixture("sinfo.txt"))}
    assert r["gpu-4-a100"].total == 1 and r["amd-512"].total == 56
    assert r["amd-512"].livres == 13 and len(r) == 10


def test_sacct_real_tem_falha_e_sucesso():
    linhas = {x.job_id: x for x in ler_sacct(fixture("sacct.txt"))}
    assert estado_slurm(linhas["2121048"].estado) == EstadoJob.FALHOU
    assert linhas["2121048"].codigo_saida == "127:0"
    assert estado_slurm(linhas["2121060"].estado) == EstadoJob.OK
    assert linhas["2121060"].decorrido == "00:02:25"
    assert estado_slurm(linhas["2121067"].estado) == EstadoJob.CANCELADO


def test_squeue_le_as_seis_colunas():
    linhas = ler_squeue(fixture("squeue_array.txt"))
    assert len(linhas) == 5
    assert linhas[0] == LinhaSqueue("2200000_[48-65%16]", "treino", "PENDING", "0:00",
                                    "amd-512", "(JobArrayTaskLimit)")


def test_array_agrupado():
    jobs = agrupar("npad", ler_squeue(fixture("squeue_array.txt")), historico_com_44_ok(),
                   {"2200000": registro(array_total=65)})
    a = next(j for j in jobs if j.id == "2200000")
    assert (a.estado, a.array_ok, a.array_total, a.externo) == (EstadoJob.RODANDO, 44, 65, False)
    assert (a.nome, a.projeto, a.log) == ("treino", "pose", "/l/%A_%a.out")
    assert a.decorrido == "12:30"
    assert a.motivo == "(JobArrayTaskLimit)"
    simples = next(j for j in jobs if j.id == "2200100")
    assert simples.externo is True and simples.estado == EstadoJob.FILA
    assert simples.motivo == "(Resources)"
    assert len(jobs) == 2


def test_squeue_e_autoridade_e_ninguem_conta_duas_vezes():
    hist = historico_com_44_ok() + [
        LinhaSacct("2200000_45", "treino", "RUNNING", "0:0", "00:12:30"),
        LinhaSacct("2200000_[48-65]", "treino", "PENDING", "0:0", "00:00:00"),
        LinhaSacct("2200100", "infer", "PENDING", "0:0", "00:00:00"),
    ]
    jobs = agrupar("npad", ler_squeue(fixture("squeue_array.txt")), hist, {})
    assert len(jobs) == 2
    a = next(j for j in jobs if j.id == "2200000")
    assert a.array_total == 65 and a.array_ok == 44 and a.externo is True


def test_array_de_1000_tarefas_vira_uma_linha():
    fila = [LinhaSqueue("9_[11-1000%50]", "big", "PENDING", "0:00", "amd-512", "(JobArrayTaskLimit)")] + rodando(9, range(1, 11))
    jobs = agrupar("npad", fila, [], {})
    assert len(jobs) == 1 and jobs[0].array_total == 1000


def test_array_so_pendente_e_fila_e_sem_decorrido():
    fila = [LinhaSqueue("7_[1-4]", "x", "PENDING", "0:00", "amd-512", "(Priority)")]
    (j,) = agrupar("npad", fila, [], {})
    assert (j.estado, j.decorrido, j.motivo, j.array_total) == (EstadoJob.FILA, "", "(Priority)", 4)


def test_array_terminado_so_no_historico():
    hist = [LinhaSacct("5_1", "a", "COMPLETED", "0:0", "00:01:00"),
            LinhaSacct("5_2", "a", "FAILED", "1:0", "00:00:05")]
    (j,) = agrupar("npad", [], hist, {})
    assert (j.estado, j.array_ok, j.array_total) == (EstadoJob.FALHOU, 1, 2)
    hist[1] = LinhaSacct("5_2", "a", "COMPLETED", "0:0", "00:00:05")
    (j,) = agrupar("npad", [], hist, {})
    assert j.estado == EstadoJob.OK


def test_job_simples_so_no_historico():
    (j,) = agrupar("npad", [], ler_sacct(fixture("sacct.txt"))[:1], {})
    assert (j.id, j.estado, j.decorrido, j.array_total) == ("2121048", EstadoJob.FALHOU, "00:00:00", None)


@pytest.mark.parametrize("txt,esp", [
    ("CANCELLED by 1234", EstadoJob.CANCELADO),
    ("CANCELLED", EstadoJob.CANCELADO),
    ("OUT_OF_MEMORY", EstadoJob.FALHOU),
    ("COMPLETING", EstadoJob.RODANDO),
    ("PENDING", EstadoJob.FILA),
    ("COMPLETED", EstadoJob.OK),
    ("TIMEOUT", EstadoJob.FALHOU),
    ("REQUEUED", EstadoJob.DESCONHECIDO),
])
def test_estados(txt, esp):
    assert estado_slurm(txt) == esp
