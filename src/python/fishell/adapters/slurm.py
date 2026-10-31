"""Adaptador do NPAD (SLURM sobre SSH)."""

from __future__ import annotations

import os
import re
import shlex
from dataclasses import replace
from datetime import datetime, timedelta

from ..core.estado import Estado, RegistroJob
from ..core.modelos import (
    TERMINAIS,
    ErroReceita,
    EstadoJob,
    Job,
    Receita,
    Recurso,
    SecaoReceita,
)
from .base import Saida
from .conexao import Conexao
from .slurm_saidas import (
    CAMPOS_SACCT,
    FMT_SINFO,
    FMT_SQUEUE,
    _dividir,
    _segundos,
    _tarefas,
    agrupar,
    estado_slurm,
    ler_sacct,
    ler_sinfo,
    ler_squeue,
)

SEP_SACCT = "@@fishell-separador-sacct-7f3a9c@@"
SEP_LOGS = "@@fishell-separador-logs-7f3a9c@@"
MARCA_LOG = "@@fishell-log "
LOG_EXTERNO = "(log indisponível para job externo)"
_ID_SCRIPT = re.compile(r"^fishell-job:\s*(\d+)\s*$", re.MULTILINE)
_ID_SBATCH = re.compile(r"^\s*(\d+)")

_SQUEUE = f"squeue -h -u \"$USER\" -o {shlex.quote(FMT_SQUEUE)}"
_SACCT = f'sacct -u "$USER" -S now-1days -X -n -P -o {CAMPOS_SACCT}'


def _q(x: str) -> str:
    return shlex.quote(x)


def _tail_um(log: str) -> str:
    """`tail -n 1` de um log; com `%a`, do arquivo mais recente que casa."""
    if "%a" not in log:
        return f"tail -n 1 -- {_q(log)} 2>/dev/null"
    padrao = "*".join(_q(p) for p in log.split("%a"))
    return (
        f'f=$(ls -t -- {padrao} 2>/dev/null | head -n 1); '
        '[ -n "$f" ] && tail -n 1 -- "$f" 2>/dev/null'
    )


class AdaptadorSlurm:
    intervalo = 60.0
    capacidades = frozenset({"enviar", "trazer", "ambiente", "submeter", "cancelar", "log"})

    def __init__(
        self,
        nome: str,
        conexao: Conexao,
        estado: Estado,
        particoes: tuple[str, ...] = (),
    ) -> None:
        self.nome = nome
        self.conexao = conexao
        self.estado = estado
        self.particoes = tuple(particoes)

    # --- receita -----------------------------------------------------
    def _secao(self, receita: Receita) -> SecaoReceita:
        secao = receita.secoes.get(self.nome)
        if secao is None:
            raise ErroReceita(f"a receita não tem a seção do destino {self.nome!r}")
        return secao

    def _base(self, secao: SecaoReceita) -> str:
        if not secao.remoto:
            raise ErroReceita(f"a seção {self.nome!r} não define `remoto`")
        return self.conexao.resolver(secao.remoto)

    # --- leitura -----------------------------------------------------
    def listar_jobs(self) -> list[Job]:
        ativos = self.estado.ativos(self.nome)
        partes = [_SQUEUE, f"echo {SEP_SACCT}", _SACCT, f"echo {SEP_LOGS}"]
        for r in ativos:
            if r.log:
                partes.append(f"echo {_q(MARCA_LOG + r.job_id)}")
                partes.append(_tail_um(r.log))
        r = self.conexao.comando("; ".join(partes))
        if r.codigo != 0 and SEP_SACCT not in r.saida:
            raise RuntimeError(r.erro.strip() or f"squeue falhou ({r.codigo})")
        texto_fila, _, resto = r.saida.partition(SEP_SACCT)
        texto_hist, _, texto_logs = resto.partition(SEP_LOGS)

        registros = {x.job_id: x for x in self._registros()}
        jobs = agrupar(self.nome, ler_squeue(texto_fila), ler_sacct(texto_hist), registros)
        ultimas = self._ultimas_linhas(texto_logs)
        saida: list[Job] = []
        for j in jobs:
            if j.estado in TERMINAIS:
                self.estado.atualizar(self.nome, j.id, j.estado)
            if j.estado not in TERMINAIS and ultimas.get(j.id):
                j = replace(j, ultima_linha=ultimas[j.id])
            saida.append(j)
        return saida

    def _registros(self) -> list[RegistroJob]:
        desde = datetime.now() - timedelta(days=1)
        return self.estado.ativos(self.nome) + self.estado.recentes(self.nome, desde)

    @staticmethod
    def _ultimas_linhas(texto: str) -> dict[str, str]:
        ultimas: dict[str, str] = {}
        atual: str | None = None
        for linha in texto.splitlines():
            if linha.startswith(MARCA_LOG):
                atual = linha[len(MARCA_LOG):].strip()
                ultimas[atual] = ""
            elif atual is not None and linha.strip():
                ultimas[atual] = linha.strip()
        return ultimas

    def recursos(self) -> list[Recurso]:
        r = self.conexao.comando(f"sinfo -h -o {_q(FMT_SINFO)}")
        if r.codigo != 0:
            raise RuntimeError(r.erro.strip() or f"sinfo falhou ({r.codigo})")
        todos = ler_sinfo(r.saida)
        if not self.particoes:
            return todos
        return [x for x in todos if x.rotulo in self.particoes]

    # --- transferência -----------------------------------------------
    def enviar(self, receita: Receita, saida: Saida) -> None:
        secao = self._secao(receita)
        base = self._base(secao)
        destinos = []
        for t in secao.enviar:
            remoto = f"{base}/{t.para}"
            destinos.append(remoto if t.para.endswith("/") else os.path.dirname(remoto))
        r = self.conexao.comando(
            "mkdir -p " + " ".join(_q(d) for d in dict.fromkeys([base, *destinos]))
        )
        if r.codigo != 0:
            raise RuntimeError(r.erro.strip() or "não criei as pastas remotas")
        for t in secao.enviar:
            origem = os.path.join(str(receita.raiz), t.de)
            destino = f"{self.conexao.alias}:{base}/{t.para}"
            self._rsync(origem, destino, t, saida)

    def trazer(self, receita: Receita, saida: Saida) -> None:
        secao = self._secao(receita)
        base = self._base(secao)
        for t in secao.trazer:
            origem = f"{self.conexao.alias}:{base}/{t.de}"
            destino = os.path.join(str(receita.raiz), t.para)
            pasta = destino if t.para.endswith("/") else os.path.dirname(destino)
            os.makedirs(pasta, exist_ok=True)
            self._rsync(origem, destino, t, saida)

    def _rsync(self, origem, destino, t, saida: Saida) -> None:
        r = self.conexao.rsync(origem, destino, t, saida=saida)
        if r.codigo != 0:
            raise RuntimeError(r.erro.strip() or f"rsync saiu com {r.codigo}")

    # --- execução ----------------------------------------------------
    def montar_ambiente(self, receita: Receita, saida: Saida) -> int:
        secao = self._secao(receita)
        if not secao.ambiente:
            raise ErroReceita(f"a seção {self.nome!r} não define `ambiente`")
        base = self._base(secao)
        r = self.conexao.comando(
            f"cd {_q(base)} && bash {_q(secao.ambiente)}", saida=saida
        )
        return r.codigo

    def submeter(
        self, receita: Receita, particao: str | None, array: str | None, saida: Saida
    ) -> str:
        secao = self._secao(receita)
        base = self._base(secao)
        projeto = receita.nome
        if secao.job:
            particao = particao or secao.particao
            if not particao:
                raise ErroReceita(f"sem partição para submeter em {self.nome!r}")
            modelo = secao.log or (
                "logs/fishell_%A_%a.out" if array else "logs/fishell_%j.out"
            )
            log_abs = modelo if modelo.startswith("/") else f"{base}/{modelo}"
            opcoes = f"--parsable -p {_q(particao)}"
            if array:
                opcoes += f" --array={_q(array)}"
            cmd = (
                f"mkdir -p {_q(os.path.dirname(log_abs))} && cd {_q(base)} && "
                f"sbatch {opcoes} -o {_q(log_abs)} {_q(secao.job)}"
            )
            r = self.conexao.comando(cmd)
            m = _ID_SBATCH.match(r.saida) if r.codigo == 0 else None
            if not m:
                raise RuntimeError(
                    (r.erro or r.saida).strip() or f"sbatch saiu com {r.codigo}"
                )
            nome = os.path.splitext(os.path.basename(secao.job))[0]
        elif secao.submeter:
            r = self.conexao.comando(
                f"cd {_q(base)} && bash {_q(secao.submeter)}", saida=saida
            )
            m = _ID_SCRIPT.search(r.saida)
            if not m:
                raise ErroReceita(
                    "o script de submissão não imprimiu `fishell-job: <id>`. Saída:\n"
                    + r.saida
                )
            log_abs = None
            if secao.log:
                log_abs = secao.log if secao.log.startswith("/") else f"{base}/{secao.log}"
            nome = projeto
        else:
            raise ErroReceita(f"a seção {self.nome!r} não define `job` nem `submeter`")
        id_ = m.group(1)
        log = log_abs.replace("%j", id_).replace("%A", id_) if log_abs else None
        total = len(_tarefas(array)) if array else None
        self.estado.registrar(self.nome, id_, projeto, nome, log, total)
        return id_

    def cancelar(self, job_id: str) -> None:
        r = self.conexao.comando(f"scancel {_q(job_id)}")
        if r.codigo != 0:
            raise RuntimeError(r.erro.strip() or f"scancel saiu com {r.codigo}")

    # --- log ---------------------------------------------------------
    def log(self, job: Job, linhas: int = 40) -> list[str]:
        if job.externo or not job.log:
            return [LOG_EXTERNO]
        caminho = job.log
        if "%a" in caminho:
            tarefa = self._tarefa_recente(job.id)
            if tarefa is None:
                return ["(nenhuma tarefa com log ainda)"]
            caminho = caminho.replace("%a", tarefa)
        r = self.conexao.comando(f"tail -n {int(linhas)} -- {_q(caminho)}")
        if r.codigo != 0:
            return [f"(log indisponível: {r.erro.strip() or r.codigo})"]
        return r.saida.splitlines()

    def _tarefa_recente(self, job_id: str) -> str | None:
        cmd = (
            f"squeue -h -j {_q(job_id)} -o {_q(FMT_SQUEUE)}; echo {SEP_SACCT}; "
            f"sacct -j {_q(job_id)} -X -n -P -o {CAMPOS_SACCT}"
        )
        r = self.conexao.comando(cmd)
        texto_fila, _, texto_hist = r.saida.partition(SEP_SACCT)
        rodando = []
        for l in ler_squeue(texto_fila):
            _, t = _dividir(l.job_id)
            if t and t.isdigit() and estado_slurm(l.estado) == EstadoJob.RODANDO:
                rodando.append((_segundos(l.decorrido), -int(t), t))
        if rodando:
            return min(rodando)[2]
        feitas = []
        for l in ler_sacct(texto_hist):
            _, t = _dividir(l.job_id)
            if t and t.isdigit() and estado_slurm(l.estado) in TERMINAIS:
                feitas.append(int(t))
        return str(max(feitas)) if feitas else None
