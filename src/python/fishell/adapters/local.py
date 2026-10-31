"""Adaptador local: jobs na GPU desta máquina, dentro de sessões tmux."""

from __future__ import annotations

import shlex
from datetime import datetime, timedelta
from pathlib import Path

from ..core.estado import Estado
from ..core.modelos import TERMINAIS, ErroReceita, EstadoJob, Job, Receita, Recurso, SecaoReceita
from .base import Saida
from .conexao import Executor, executar_subprocess

_CAUDA = 8192
_NVIDIA = [
    "nvidia-smi",
    "--query-gpu=name,utilization.gpu,memory.used,memory.total",
    "--format=csv,noheader,nounits",
]


def _q(x: str) -> str:
    return shlex.quote(x)


def _decorrido(inicio: datetime) -> str:
    s = max(0, int((datetime.now() - inicio).total_seconds()))
    h, resto = divmod(s, 3600)
    m, s = divmod(resto, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


class AdaptadorLocal:
    nome = "local"
    intervalo = 3.0
    capacidades = frozenset({"ambiente", "submeter", "cancelar", "log"})

    def __init__(
        self,
        estado: Estado,
        dir_jobs: Path,
        executar: Executor = executar_subprocess,
        tmux_socket: str | None = None,
    ) -> None:
        self.estado = estado
        self.dir_jobs = Path(dir_jobs)
        self.dir_jobs.mkdir(parents=True, exist_ok=True)
        self._executar = executar
        self._socket = tmux_socket

    # --- apoio -------------------------------------------------------
    def _tmux(self, *args: str):
        pre = ["-L", self._socket] if self._socket else []
        return self._executar(["tmux", *pre, *args], 30, None)

    def _secao(self, receita: Receita) -> SecaoReceita:
        secao = receita.secoes.get(self.nome)
        if secao is None:
            raise ErroReceita(f"a receita não tem a seção do destino {self.nome!r}")
        return secao

    def _novo_id(self) -> str:
        base = "l" + datetime.now().strftime("%Y%m%d-%H%M%S")
        usados = {r.job_id for r in self.estado.recentes(self.nome, datetime.min)}
        id_, n = base, 1
        while id_ in usados:
            n += 1
            id_ = f"{base}-{n}"
        return id_

    def _cauda(self, caminho: Path) -> str:
        try:
            with open(caminho, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - _CAUDA))
                return f.read().decode("utf-8", errors="replace")
        except OSError:
            return ""

    # --- leitura -----------------------------------------------------
    def _registros(self):
        desde = datetime.now() - timedelta(days=1)
        vistos: dict[str, object] = {}
        for r in self.estado.ativos(self.nome) + self.estado.recentes(self.nome, desde):
            vistos.setdefault(r.job_id, r)
        return sorted(vistos.values(), key=lambda r: r.inicio)

    def _sessoes(self) -> set[str] | None:
        """Sessões vivas; None quando o tmux falhou por outro motivo (desconhecido)."""
        r = self._tmux("list-sessions", "-F", "#{session_name}")
        if r.codigo == 0:
            return set(r.saida.split())
        if "no server running" in r.erro or "error connecting to" in r.erro:
            return set()
        return None

    def _codigo_saida(self, job_id: str) -> str | None:
        try:
            texto = (self.dir_jobs / f"{job_id}.exit").read_text().strip()
        except OSError:
            return None
        return texto or None

    def listar_jobs(self) -> list[Job]:
        vivas = self._sessoes()
        jobs: list[Job] = []
        for reg in self._registros():
            motivo = ""
            codigo = self._codigo_saida(reg.job_id)
            if reg.estado in TERMINAIS:
                est = reg.estado
                if est == EstadoJob.FALHOU and codigo is None:
                    motivo = "sessão sumiu"
            elif codigo is not None:
                est = EstadoJob.OK if codigo == "0" else EstadoJob.FALHOU
                self.estado.atualizar(self.nome, reg.job_id, est)
            elif vivas is None:
                est = reg.estado
            elif f"fishell-{reg.job_id}" in vivas:
                est = EstadoJob.RODANDO
                if reg.estado != est:
                    self.estado.atualizar(self.nome, reg.job_id, est)
            else:
                est = EstadoJob.FALHOU
                motivo = "sessão sumiu"
                self.estado.atualizar(self.nome, reg.job_id, est)
            ultima = ""
            if reg.log:
                linhas = [l for l in self._cauda(Path(reg.log)).splitlines() if l.strip()]
                ultima = linhas[-1] if linhas else ""
            jobs.append(
                Job(
                    destino=self.nome, id=reg.job_id, nome=reg.nome, estado=est,
                    decorrido=_decorrido(reg.inicio), projeto=reg.projeto,
                    ultima_linha=ultima, array_total=reg.array_total,
                    log=reg.log, motivo=motivo,
                )
            )  # fmt: skip
        return jobs

    def recursos(self) -> list[Recurso]:
        r = self._executar(_NVIDIA, 15, None)
        if r.codigo != 0:
            return []
        saida: list[Recurso] = []
        for linha in r.saida.splitlines():
            campos = [c.strip() for c in linha.split(",")]
            if len(campos) != 4:
                continue
            nome = campos[0].removeprefix("NVIDIA ").removeprefix("GeForce ")
            try:
                util = int(float(campos[1]))
                usada = round(float(campos[2]) / 1024)
                total = round(float(campos[3]) / 1024)
            except ValueError:
                continue
            saida.append(Recurso(rotulo=nome, texto=f"{util}% {usada}/{total}G"))
        return saida

    # --- ações -------------------------------------------------------
    def enviar(self, receita: Receita, saida: Saida) -> None:
        pass

    def trazer(self, receita: Receita, saida: Saida) -> None:
        pass

    def montar_ambiente(self, receita: Receita, saida: Saida) -> int:
        secao = self._secao(receita)
        if not secao.ambiente:
            raise ErroReceita("a seção 'local' não define `ambiente`")
        cmd = f"cd {_q(str(receita.raiz))} && bash {_q(secao.ambiente)}"
        return self._executar(["bash", "-c", cmd], None, saida).codigo

    def submeter(
        self, receita: Receita, particao: str | None, array: str | None, saida: Saida
    ) -> str:
        secao = self._secao(receita)
        if not secao.comando:
            raise ErroReceita("a seção 'local' não define `comando`")
        id_ = self._novo_id()
        log = self.dir_jobs / f"{id_}.log"
        fim = self.dir_jobs / f"{id_}.exit"
        script = (
            f"bash -c {_q(secao.comando)} > {_q(str(log))} 2>&1; "
            f"echo $? > {_q(str(fim))}"
        )
        r = self._tmux(
            "new-session", "-d", "-s", f"fishell-{id_}", "-c", str(receita.raiz),
            "bash", "-c", script,
        )  # fmt: skip
        if r.codigo != 0:
            raise RuntimeError(r.erro.strip() or f"tmux saiu com {r.codigo}")
        self.estado.registrar(self.nome, id_, receita.nome, receita.nome, str(log), None)
        return id_

    def cancelar(self, job_id: str) -> None:
        self._tmux("kill-session", "-t", f"fishell-{job_id}")
        self.estado.atualizar(self.nome, job_id, EstadoJob.CANCELADO)

    def log(self, job: Job, linhas: int = 40) -> list[str]:
        if not job.log:
            return []
        return self._cauda(Path(job.log)).splitlines()[-int(linhas):]
