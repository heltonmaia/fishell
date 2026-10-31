"""Modelos de dados do núcleo (sem dependência de interface)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path


class EstadoJob(StrEnum):
    FILA = "fila"
    RODANDO = "rodando"
    OK = "ok"
    FALHOU = "falhou"
    CANCELADO = "cancelado"
    DESCONHECIDO = "desconhecido"


TERMINAIS = frozenset({EstadoJob.OK, EstadoJob.FALHOU, EstadoJob.CANCELADO})


@dataclass(frozen=True)
class Job:
    destino: str
    id: str
    nome: str
    estado: EstadoJob
    decorrido: str = ""
    projeto: str | None = None
    ultima_linha: str = ""
    externo: bool = False
    array_total: int | None = None
    array_ok: int | None = None
    log: str | None = None
    motivo: str = ""


@dataclass(frozen=True)
class Recurso:
    rotulo: str
    livres: int | None = None
    total: int | None = None
    texto: str = ""


@dataclass(frozen=True)
class Transferencia:
    de: str
    para: str
    incluir: tuple[str, ...] = ()
    excluir: tuple[str, ...] = ()


@dataclass(frozen=True)
class SecaoReceita:
    destino: str
    remoto: str | None
    enviar: tuple[Transferencia, ...]
    trazer: tuple[Transferencia, ...]
    ambiente: str | None
    job: str | None
    submeter: str | None
    comando: str | None
    particao: str | None
    log: str | None


@dataclass(frozen=True)
class Receita:
    raiz: Path
    nome: str
    secoes: dict[str, SecaoReceita]
    erro: str | None = None


class ErroReceita(ValueError):
    pass
