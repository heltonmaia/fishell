"""Formatação de jobs compartilhada entre a tela e o `fishell jobs`."""

from . import textos
from .core.modelos import EstadoJob, Job


def texto_estado(job: Job) -> str:
    e = job.estado
    if e == EstadoJob.RODANDO:
        if job.array_total:
            return textos.TUI_ESTADO_ARRAY.format(ok=job.array_ok or 0, total=job.array_total)
        return textos.TUI_ESTADO_RODANDO
    return {
        EstadoJob.FILA: textos.TUI_ESTADO_FILA,
        EstadoJob.OK: textos.TUI_ESTADO_OK,
        EstadoJob.FALHOU: textos.TUI_ESTADO_FALHOU,
        EstadoJob.CANCELADO: textos.TUI_ESTADO_CANCELADO,
    }.get(e, textos.TUI_ESTADO_DESCONHECIDO)


def linha_job(j: Job) -> tuple[str, ...]:
    return (
        j.destino,
        j.projeto or "",
        j.nome + (" *" if j.externo else ""),
        texto_estado(j),
        j.decorrido,
        j.ultima_linha or j.motivo,
    )
