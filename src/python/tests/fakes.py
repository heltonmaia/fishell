"""Adaptador falso configurável para os testes."""

from __future__ import annotations

import time

from fishell.core.modelos import Job, Receita, Recurso

TODAS = frozenset({"enviar", "trazer", "ambiente", "submeter", "cancelar", "log"})


class AdaptadorFalso:
    def __init__(
        self,
        nome: str = "falso",
        jobs: tuple[Job, ...] | list[Job] = (),
        recursos: tuple[Recurso, ...] | list[Recurso] = (),
        erro: Exception | None = None,
        atraso: float = 0.0,
        intervalo: float = 60.0,
        capacidades: frozenset[str] = TODAS,
        id_submetido: str = "999",
        linhas_log: tuple[str, ...] | list[str] = (),
        codigo_ambiente: int = 0,
    ) -> None:
        self.nome = nome
        self.intervalo = intervalo
        self.capacidades = capacidades
        self.erro = erro
        self.atraso = atraso
        self.id_submetido = id_submetido
        self.codigo_ambiente = codigo_ambiente
        self._jobs = list(jobs)
        self._recursos = list(recursos)
        self._linhas_log = list(linhas_log)
        self.chamadas: list[tuple[str, tuple]] = []

    def _dormir(self) -> None:
        if self.atraso:
            time.sleep(self.atraso)

    def listar_jobs(self) -> list[Job]:
        self.chamadas.append(("listar_jobs", ()))
        if self.erro is not None:
            raise self.erro
        return list(self._jobs)

    def recursos(self) -> list[Recurso]:
        self.chamadas.append(("recursos", ()))
        if self.erro is not None:
            raise self.erro
        return list(self._recursos)

    def enviar(self, receita: Receita, saida) -> None:
        self.chamadas.append(("enviar", (receita, saida)))
        self._dormir()

    def trazer(self, receita: Receita, saida) -> None:
        self.chamadas.append(("trazer", (receita, saida)))
        self._dormir()

    def montar_ambiente(self, receita: Receita, saida) -> int:
        self.chamadas.append(("montar_ambiente", (receita, saida)))
        self._dormir()
        return self.codigo_ambiente

    def submeter(self, receita: Receita, particao, array, saida) -> str:
        self.chamadas.append(("submeter", (receita, particao, array, saida)))
        self._dormir()
        return self.id_submetido

    def cancelar(self, job_id: str) -> None:
        self.chamadas.append(("cancelar", (job_id,)))

    def log(self, job: Job, linhas: int = 40) -> list[str]:
        self.chamadas.append(("log", (job, linhas)))
        return list(self._linhas_log)
