"""Leitura das saídas do SLURM (squeue, sacct, sinfo). Funções puras."""

from __future__ import annotations

import re
from dataclasses import dataclass

from ..core.estado import RegistroJob
from ..core.modelos import EstadoJob, Job, Recurso

FMT_SQUEUE = "%i|%j|%T|%M|%P|%R"
CAMPOS_SACCT = "JobID,JobName,State,ExitCode,Elapsed"
FMT_SINFO = "%R|%F"


@dataclass(frozen=True)
class LinhaSqueue:
    job_id: str
    nome: str
    estado: str
    decorrido: str
    particao: str
    motivo: str


@dataclass(frozen=True)
class LinhaSacct:
    job_id: str
    nome: str
    estado: str
    codigo_saida: str
    decorrido: str


_ESTADOS = {
    "PENDING": EstadoJob.FILA,
    "RUNNING": EstadoJob.RODANDO,
    "COMPLETING": EstadoJob.RODANDO,
    "CONFIGURING": EstadoJob.RODANDO,
    "COMPLETED": EstadoJob.OK,
    "FAILED": EstadoJob.FALHOU,
    "TIMEOUT": EstadoJob.FALHOU,
    "OUT_OF_MEMORY": EstadoJob.FALHOU,
    "NODE_FAIL": EstadoJob.FALHOU,
    "BOOT_FAIL": EstadoJob.FALHOU,
    "PREEMPTED": EstadoJob.FALHOU,
}


def estado_slurm(texto: str) -> EstadoJob:
    t = texto.strip().upper()
    if t.startswith("CANCELLED"):
        return EstadoJob.CANCELADO
    return _ESTADOS.get(t, EstadoJob.DESCONHECIDO)


def _linhas(texto: str, n: int) -> list[list[str]]:
    saida = []
    for linha in texto.splitlines():
        partes = linha.strip().split("|", n - 1)
        if len(partes) == n:
            saida.append([p.strip() for p in partes])
    return saida


def ler_squeue(texto: str) -> list[LinhaSqueue]:
    return [LinhaSqueue(*p) for p in _linhas(texto, 6)]


def ler_sacct(texto: str) -> list[LinhaSacct]:
    return [LinhaSacct(*p) for p in _linhas(texto, 5)]


def ler_sinfo(texto: str) -> list[Recurso]:
    recursos = []
    for rotulo, contagem in _linhas(texto, 2):
        nums = contagem.split("/")
        if len(nums) != 4 or not all(n.isdigit() for n in nums):
            continue
        recursos.append(Recurso(rotulo=rotulo, livres=int(nums[1]), total=int(nums[3])))
    return recursos


def _tarefas(spec: str) -> set[str]:
    """Expande `4`, `[5-65%16]` ou `[1,3,5-7]` em ids de tarefa."""
    spec = spec.strip()
    if spec.startswith("["):
        spec = spec.strip("[]")
    spec = spec.split("%")[0]
    ids: set[str] = set()
    for parte in spec.split(","):
        parte = parte.split(":")[0] if "-" not in parte else parte
        m = re.fullmatch(r"(\d+)-(\d+)(?::\d+)?", parte)
        if m:
            ids.update(str(i) for i in range(int(m[1]), int(m[2]) + 1))
        elif parte:
            ids.add(parte)
    return ids


def _dividir(job_id: str) -> tuple[str, str | None]:
    base, sep, resto = job_id.partition("_")
    return base, (resto if sep else None)


def _segundos(decorrido: str) -> int:
    dias, _, resto = decorrido.rpartition("-")
    try:
        partes = [int(p) for p in resto.split(":")]
        total = 0
        for p in partes:
            total = total * 60 + p
        return total + (int(dias) * 86400 if dias else 0)
    except ValueError:
        return -1


@dataclass
class _Grupo:
    nome: str
    array: bool = False
    # squeue: tarefa -> (estado, decorrido, motivo); None = job simples
    fila: dict[str | None, tuple[EstadoJob, str, str]] = None  # type: ignore[assignment]
    hist: dict[str | None, tuple[EstadoJob, str]] = None  # type: ignore[assignment]

    def __post_init__(self):
        self.fila = {}
        self.hist = {}


def agrupar(
    destino: str,
    fila: list[LinhaSqueue],
    historico: list[LinhaSacct],
    registros: dict[str, RegistroJob],
) -> list[Job]:
    grupos: dict[str, _Grupo] = {}

    for l in fila:
        base, spec = _dividir(l.job_id)
        g = grupos.setdefault(base, _Grupo(l.nome))
        g.array = g.array or spec is not None
        estado = estado_slurm(l.estado)
        alvos = _tarefas(spec) if spec is not None else {None}
        for t in alvos:
            g.fila[t] = (estado, l.decorrido, l.motivo)

    for l in historico:
        base, spec = _dividir(l.job_id)
        g = grupos.setdefault(base, _Grupo(l.nome))
        g.array = g.array or spec is not None
        alvos = _tarefas(spec) if spec is not None else {None}
        for t in alvos:
            if t not in g.fila:  # squeue manda no que ainda lista
                g.hist[t] = (estado_slurm(l.estado), l.decorrido)

    jobs = []
    for base, g in grupos.items():
        reg = registros.get(base)
        if not g.array:
            jobs.append(_job_simples(destino, base, g, reg))
        else:
            jobs.append(_job_array(destino, base, g, reg))
    return jobs


def _job_simples(destino: str, base: str, g: _Grupo, reg: RegistroJob | None) -> Job:
    if None in g.fila:
        estado, decorrido, motivo = g.fila[None]
        motivo = motivo if estado == EstadoJob.FILA else ""
    else:
        estado, decorrido = g.hist[None]
        motivo = ""
    return Job(
        destino=destino, id=base, nome=reg.nome if reg else g.nome, estado=estado,
        decorrido=decorrido, projeto=reg.projeto if reg else None,
        externo=reg is None, log=reg.log if reg else None, motivo=motivo,
    )


def _job_array(destino: str, base: str, g: _Grupo, reg: RegistroJob | None) -> Job:
    estados = [e for e, _, _ in g.fila.values()] + [e for e, _ in g.hist.values()]
    ok = sum(1 for e in estados if e == EstadoJob.OK)
    if EstadoJob.RODANDO in estados:
        estado = EstadoJob.RODANDO
    elif EstadoJob.FILA in estados:
        estado = EstadoJob.FILA
    elif EstadoJob.FALHOU in estados:
        estado = EstadoJob.FALHOU
    elif EstadoJob.CANCELADO in estados:
        estado = EstadoJob.CANCELADO
    elif EstadoJob.DESCONHECIDO in estados:
        estado = EstadoJob.DESCONHECIDO
    else:
        estado = EstadoJob.OK
    rodando = [d for e, d, _ in g.fila.values() if e == EstadoJob.RODANDO]
    decorrido = max(rodando, key=_segundos) if rodando else ""
    motivos = [m for e, _, m in g.fila.values() if e == EstadoJob.FILA]
    total = reg.array_total if reg and reg.array_total is not None else len(estados)
    return Job(
        destino=destino, id=base, nome=reg.nome if reg else g.nome, estado=estado,
        decorrido=decorrido, projeto=reg.projeto if reg else None,
        externo=reg is None, array_total=total, array_ok=ok,
        log=reg.log if reg else None, motivo=motivos[0] if motivos else "",
    )
