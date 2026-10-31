"""Interface comum dos adaptadores de destino."""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from typing import Protocol

from ..core.modelos import Job, Receita, Recurso

Saida = Callable[[str], None]


class Indisponivel(Exception):
    """Destino bloqueado até `ate` (conexão recusada)."""

    def __init__(self, ate: datetime, motivo: str = "") -> None:
        super().__init__(motivo or f"indisponível até {ate:%H:%M}")
        self.ate = ate
        self.motivo = motivo


class ErroAutenticacao(Exception):
    """Falha de autenticação (não é recusa; sem espera)."""


class Adaptador(Protocol):
    nome: str
    intervalo: float
    capacidades: frozenset[str]

    def listar_jobs(self) -> list[Job]: ...

    def recursos(self) -> list[Recurso]: ...

    def enviar(self, receita: Receita, saida: Saida) -> None: ...

    def trazer(self, receita: Receita, saida: Saida) -> None: ...

    def montar_ambiente(self, receita: Receita, saida: Saida) -> int: ...

    def submeter(
        self, receita: Receita, particao: str | None, array: str | None, saida: Saida
    ) -> str: ...

    def cancelar(self, job_id: str) -> None: ...

    def log(self, job: Job, linhas: int = 40) -> list[str]: ...
