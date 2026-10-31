"""Conexão SSH única (ControlMaster) com o NPAD.

O NPAD bloqueia a conta por cerca de 30 minutos depois de muitas conexões
novas em poucos minutos. Por isso toda chamada ssh/rsync reaproveita o mesmo
socket e uma recusa interrompe qualquer nova tentativa durante 30 minutos.
"""

from __future__ import annotations

import shlex
import subprocess
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from ..core.modelos import Transferencia
from .base import ErroAutenticacao, Indisponivel, Saida

BLOQUEIO = timedelta(minutes=30)


@dataclass(frozen=True)
class Resultado:
    codigo: int
    saida: str
    erro: str


Executor = Callable[[list[str], float, "Saida | None"], Resultado]


def executar_subprocess(argv: list[str], timeout: float, saida: Saida | None) -> Resultado:
    try:
        p = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            text=True,
            errors="replace",
        )
    except FileNotFoundError as e:
        return Resultado(127, "", str(e))
    erro: list[str] = []
    leitor = threading.Thread(target=lambda: erro.append(p.stderr.read()), daemon=True)
    leitor.start()
    expirou = threading.Event()

    def matar() -> None:
        expirou.set()
        p.kill()

    timer = threading.Timer(timeout, matar)
    timer.start()
    linhas: list[str] = []
    try:
        for linha in p.stdout:
            linha = linha.rstrip("\n")
            linhas.append(linha)
            if saida is not None:
                saida(linha)
        p.wait()
    finally:
        timer.cancel()
        leitor.join()
    texto_erro = "".join(erro)
    if expirou.is_set():
        return Resultado(124, "\n".join(linhas), texto_erro or "tempo esgotado")
    return Resultado(p.returncode, "\n".join(linhas), texto_erro)


class Conexao:
    def __init__(
        self,
        alias: str,
        dir_ctl: Path,
        executar: Executor = executar_subprocess,
        agora: Callable[[], datetime] = datetime.now,
    ) -> None:
        self.alias = alias
        self.dir_ctl = Path(dir_ctl)
        self._executar = executar
        self._agora = agora
        self._bloqueado_ate: datetime | None = None
        self._cache: dict[str, str] = {}
        self._trava = threading.Lock()

    def opcoes_ssh(self) -> list[str]:
        self.dir_ctl.mkdir(mode=0o700, parents=True, exist_ok=True)
        return [
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={self.dir_ctl}/%C",
            "-o", "ControlPersist=600",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=45",
            "-o", "ServerAliveInterval=30",
        ]  # fmt: skip

    def _verificar(self) -> None:
        ate = self._bloqueado_ate
        if ate is not None:
            if self._agora() < ate:
                raise Indisponivel(ate, "conexão recusada")
            self._bloqueado_ate = None

    def _rodar(self, argv: list[str], timeout: float, saida: Saida | None) -> Resultado:
        with self._trava:
            self._verificar()
            r = self._executar(argv, timeout, saida)
            if r.codigo == 255:
                if "Permission denied" in r.erro:
                    raise ErroAutenticacao(r.erro.strip())
                self._bloqueado_ate = self._agora() + BLOQUEIO
                raise Indisponivel(self._bloqueado_ate, r.erro.strip())
            return r

    def comando(
        self, remoto: str, timeout: float = 60, saida: Saida | None = None
    ) -> Resultado:
        return self._rodar(["ssh", *self.opcoes_ssh(), self.alias, remoto], timeout, saida)

    def resolver(self, caminho: str) -> str:
        if caminho in self._cache:
            return self._cache[caminho]
        original = caminho
        if caminho.startswith("~/"):
            caminho = "$HOME/" + caminho[2:]
        seguro = (
            caminho.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("`", "\\`")
            .replace("$(", "\\$(")
        )
        r = self.comando(f'printf %s "{seguro}"')
        valor = r.saida.strip()
        self._cache[original] = valor
        return valor

    def rsync(
        self, origem: str, destino: str, t: Transferencia, saida: Saida | None = None
    ) -> Resultado:
        argv = ["rsync", "-a", "-e", shlex.join(["ssh", *self.opcoes_ssh()])]
        argv += [f"--include={i}" for i in t.incluir]
        argv += [f"--exclude={e}" for e in t.excluir]
        argv += [origem, destino]
        return self._rodar(argv, 3600, saida)

    def fechar(self) -> None:
        """Encerra o mestre (ssh -O exit); nunca levanta."""
        try:
            self._executar(
                ["ssh", *self.opcoes_ssh(), "-O", "exit", self.alias], 15, None
            )
        except Exception:
            pass
