"""Núcleo que as frentes (TUI, CLI, vigia) usam."""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime

from .. import textos
from ..adapters.base import Adaptador, ErroAutenticacao, Indisponivel, Saida
from .estado import Estado
from .modelos import TERMINAIS, Job, Receita, Recurso


@dataclass
class Visao:
    jobs: list[Job] = field(default_factory=list)
    recursos: dict[str, list[Recurso]] = field(default_factory=dict)
    avisos: dict[str, str] = field(default_factory=dict)
    receitas: list[Receita] = field(default_factory=list)
    indisponivel_ate: dict[str, datetime] = field(default_factory=dict)
    sem_acesso: frozenset[str] = frozenset()


def _nada() -> None:
    pass


class Hub:
    def __init__(
        self,
        adaptadores: dict[str, Adaptador],
        estado: Estado,
        receitas: list[Receita],
        relogio: Callable[[], float] = time.monotonic,
        iniciar_vigia: Callable[[], None] = _nada,
    ) -> None:
        self.adaptadores = adaptadores
        self.estado = estado
        self.receitas = receitas
        self._relogio = relogio
        self._iniciar_vigia = iniciar_vigia
        self._trava = threading.Lock()
        self._jobs: dict[str, list[Job]] = {}
        self._recursos: dict[str, list[Recurso]] = {}
        self._avisos: dict[str, str] = {}
        self._ultima: dict[str, float] = {}
        self._em_voo: set[str] = set()
        self._sem_acesso: set[str] = set()
        self._indisp: dict[str, datetime] = {}
        self._sujos: set[str] = set()

    # --- consulta ----------------------------------------------------
    def atualizar(self, forcar: bool = False) -> Visao:
        for nome, ad in self.adaptadores.items():
            with self._trava:
                if forcar:
                    self._sem_acesso.discard(nome)
                if nome in self._em_voo or nome in self._sem_acesso:
                    continue
                ultima = self._ultima.get(nome)
                if not forcar and ultima is not None and self._relogio() - ultima < ad.intervalo:
                    continue
                self._em_voo.add(nome)
                self._sujos.discard(nome)
            jobs, recursos, aviso, auth, ate = self._consultar(ad)
            with self._trava:
                self._em_voo.discard(nome)
                if nome not in self._sujos:
                    self._ultima[nome] = self._relogio()
                self._jobs[nome] = jobs
                self._recursos[nome] = recursos
                if ate is not None:
                    self._indisp[nome] = ate
                else:
                    self._indisp.pop(nome, None)
                if aviso:
                    self._avisos[nome] = aviso
                else:
                    self._avisos.pop(nome, None)
                if auth:
                    self._sem_acesso.add(nome)
        return self._visao()

    @staticmethod
    def _consultar(ad: Adaptador):
        try:
            return ad.listar_jobs(), ad.recursos(), "", False, None
        except Indisponivel as e:
            return [], [], textos.HUB_INDISPONIVEL_ATE.format(hora=f"{e.ate:%H:%M}"), False, e.ate
        except ErroAutenticacao:
            return [], [], textos.HUB_SEM_ACESSO, True, None
        except Exception as e:  # noqa: BLE001 - nada pode derrubar a interface
            return [], [], textos.HUB_ERRO_CONSULTA.format(erro=e), False, None

    def _visao(self) -> Visao:
        with self._trava:
            jobs = [j for js in self._jobs.values() for j in js]
            jobs.sort(key=lambda j: (j.estado in TERMINAIS, j.destino, j.id))
            return Visao(
                jobs=jobs,
                recursos={k: list(v) for k, v in self._recursos.items()},
                avisos=dict(self._avisos),
                receitas=list(self.receitas),
                indisponivel_ate=dict(self._indisp),
                sem_acesso=frozenset(self._sem_acesso),
            )

    # --- ações -------------------------------------------------------
    def receita(self, projeto: str) -> Receita:
        for r in self.receitas:
            if r.nome == projeto:
                return r
        raise ValueError(textos.HUB_PROJETO_DESCONHECIDO.format(projeto=projeto))

    def _preparar(self, projeto: str, destino: str, acao: str) -> tuple[Adaptador, Receita]:
        r = self.receita(projeto)
        if r.erro:
            raise ValueError(r.erro)
        ad = self._adaptador(destino, acao)
        return ad, r

    def _adaptador(self, destino: str, acao: str | None = None) -> Adaptador:
        ad = self.adaptadores.get(destino)
        if ad is None:
            raise ValueError(textos.HUB_DESTINO_DESCONHECIDO.format(destino=destino))
        if acao is not None and acao not in ad.capacidades:
            raise ValueError(textos.HUB_SEM_CAPACIDADE.format(destino=destino, acao=acao))
        return ad

    def _vencer(self, destino: str) -> None:
        with self._trava:
            self._ultima.pop(destino, None)
            if destino in self._em_voo:
                self._sujos.add(destino)

    def enviar(self, projeto: str, destino: str, saida: Saida) -> None:
        ad, r = self._preparar(projeto, destino, "enviar")
        try:
            ad.enviar(r, saida)
        finally:
            self._vencer(destino)

    def trazer(self, projeto: str, destino: str, saida: Saida) -> None:
        ad, r = self._preparar(projeto, destino, "trazer")
        try:
            ad.trazer(r, saida)
        finally:
            self._vencer(destino)

    def montar_ambiente(self, projeto: str, destino: str, saida: Saida) -> int:
        ad, r = self._preparar(projeto, destino, "ambiente")
        try:
            return ad.montar_ambiente(r, saida)
        finally:
            self._vencer(destino)

    def submeter(
        self,
        projeto: str,
        destino: str,
        particao: str | None = None,
        array: str | None = None,
        enviar_antes: bool = True,
        *,
        saida: Saida,
    ) -> str:
        ad, r = self._preparar(projeto, destino, "submeter")
        if enviar_antes and "enviar" in ad.capacidades:
            self.enviar(projeto, destino, saida)
        try:
            job_id = ad.submeter(r, particao, array, saida)
        finally:
            self._vencer(destino)
        try:
            self._iniciar_vigia()
        except Exception as e:  # noqa: BLE001 - o job já foi submetido
            saida(textos.HUB_VIGIA_NAO_INICIOU.format(erro=e))
        return job_id

    def garantir_vigia_se_preciso(self) -> OSError | None:
        """Inicia o vigia se há job ativo ou aviso pendente (depois de um reboot, por ex.).

        Devolve o OSError que impediu de iniciá-lo, em vez de levantar.
        """
        try:
            if self.estado.ativos() or self.estado.pendentes_de_aviso():
                self._iniciar_vigia()
        except OSError as e:
            return e
        return None

    def cancelar(self, destino: str, job_id: str) -> None:
        ad = self._adaptador(destino, "cancelar")
        try:
            ad.cancelar(job_id)
        finally:
            self._vencer(destino)

    def log(self, job: Job, linhas: int = 40) -> list[str]:
        return self._adaptador(job.destino, "log").log(job, linhas)
