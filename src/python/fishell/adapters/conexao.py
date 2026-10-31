"""Conexão SSH única (ControlMaster) com o NPAD.

O NPAD bloqueia a conta por cerca de 30 minutos depois de muitas conexões
novas em poucos minutos. Por isso toda chamada ssh/rsync reaproveita o mesmo
socket e uma recusa interrompe qualquer nova tentativa durante 30 minutos.

O bloqueio fica gravado em `<dir_ctl>/<alias>.bloqueio` (a hora `ate` em ISO):
o painel, o vigia e o `fishell jobs` são processos diferentes e todos o
respeitam. Um erro que nem chegou ao cluster (DNS, rede, ControlPath longo
demais, tempo esgotado no connect) espera só 2 minutos.
"""

from __future__ import annotations

import os
import shlex
import signal
import subprocess
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from ..core.modelos import Transferencia
from .base import ErroAutenticacao, Indisponivel, Saida

BLOQUEIO = timedelta(minutes=30)
BLOQUEIO_CURTO = timedelta(minutes=2)

# o servidor recusou: 30 min (vence qualquer outra pista no mesmo erro)
_RECUSA = ("by remote host", "Connection reset", "Too many", "kex_exchange_identification")
# nunca chegou ao cluster: 2 min
_NAO_CHEGOU = (
    "Could not resolve hostname",
    "Name or service not known",
    "Temporary failure in name resolution",
    "Network is unreachable",
    "No route to host",
    "ControlPath too long",
    "too long for Unix domain socket",
)


def espera_do_erro(erro: str) -> timedelta:
    """Quanto esperar depois de um `ssh` que saiu com 255 (sem "Permission denied")."""
    if any(m in erro for m in _RECUSA):
        return BLOQUEIO
    if any(m in erro for m in _NAO_CHEGOU):
        return BLOQUEIO_CURTO
    if "connect to host" in erro and "timed out" in erro:
        # o connect() só acontece sem mestre vivo: com ele, o ssh usa o socket
        return BLOQUEIO_CURTO
    return BLOQUEIO


@dataclass(frozen=True)
class Resultado:
    codigo: int
    saida: str
    erro: str


Executor = Callable[[list[str], "float | None", "Saida | None"], Resultado]


def _matar_grupo(p: subprocess.Popen) -> None:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        p.kill()


def executar_subprocess(
    argv: list[str], timeout: float | None, saida: Saida | None
) -> Resultado:
    try:
        p = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
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
        _matar_grupo(p)

    timer = threading.Timer(timeout, matar) if timeout is not None else None
    if timer is not None:
        timer.start()
    linhas: list[str] = []
    try:
        for linha in p.stdout:
            linha = linha.rstrip("\n")
            linhas.append(linha)
            if saida is not None:
                saida(linha)
        p.wait()
    except BaseException:
        _matar_grupo(p)
        p.wait()
        leitor.join(2)
        raise
    finally:
        if timer is not None:
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
        self._longa = threading.Lock()
        self._curta = threading.Lock()
        self._estado = threading.Lock()
        self._serial = False

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

    def _arquivo_bloqueio(self) -> Path:
        return self.dir_ctl / f"{self.alias.replace('/', '_')}.bloqueio"

    def _ler_bloqueio(self) -> datetime | None:
        try:
            return datetime.fromisoformat(self._arquivo_bloqueio().read_text().strip())
        except (OSError, ValueError):
            return None

    def _gravar_bloqueio(self, ate: datetime) -> None:
        arquivo = self._arquivo_bloqueio()
        temp = arquivo.with_name(f"{arquivo.name}.{os.getpid()}.tmp")
        try:
            self.dir_ctl.mkdir(mode=0o700, parents=True, exist_ok=True)
            temp.write_text(ate.isoformat() + "\n")
            os.replace(temp, arquivo)
        except OSError:
            pass  # o bloqueio em memória continua valendo neste processo

    def _verificar(self) -> None:
        with self._estado:
            ate = self._bloqueado_ate
            gravado = self._ler_bloqueio()
            if gravado is not None and (ate is None or gravado > ate):
                ate = gravado
            if ate is not None and self._agora() < ate:
                self._bloqueado_ate = ate
                raise Indisponivel(ate)
            self._bloqueado_ate = None

    def _tentar(self, argv: list[str], timeout: float | None, saida: Saida | None) -> Resultado:
        self._verificar()
        r = self._executar(argv, timeout, saida)
        if r.codigo == 255 and not self._canal_recusado(r):
            if "Permission denied" in r.erro:
                raise ErroAutenticacao(r.erro.strip())
            with self._estado:
                ate = self._agora() + espera_do_erro(r.erro)
                self._bloqueado_ate = ate
                self._gravar_bloqueio(ate)
            raise Indisponivel(ate, r.erro.strip())
        return r

    @staticmethod
    def _canal_recusado(r: Resultado) -> bool:
        return r.codigo == 255 and (
            "mux_client_request_session" in r.erro or "Session open refused" in r.erro
        )

    def _rodar(
        self, argv: list[str], timeout: float | None, saida: Saida | None, longa: bool
    ) -> Resultado:
        lock = self._longa if (longa or self._serial) else self._curta
        with lock:
            r = self._tentar(argv, timeout, saida)
        if not self._canal_recusado(r):
            return r
        # canal extra recusado: nao e recusa da conta; passa a um canal so
        self._serial = True
        with self._longa:
            r = self._tentar(argv, timeout, saida)
        if self._canal_recusado(r):
            raise RuntimeError(r.erro.strip())
        return r

    def comando(
        self, remoto: str, timeout: float | None = 60, saida: Saida | None = None
    ) -> Resultado:
        if saida is not None:
            timeout = None
        return self._rodar(
            ["ssh", *self.opcoes_ssh(), self.alias, remoto], timeout, saida, saida is not None
        )

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
        if r.codigo != 0 or not valor:
            raise RuntimeError(f"não resolvi {original!r}: {r.erro.strip()}")
        self._cache[original] = valor
        return valor

    def rsync(
        self, origem: str, destino: str, t: Transferencia, saida: Saida | None = None
    ) -> Resultado:
        argv = ["rsync", "-a", "-s", "-e", shlex.join(["ssh", *self.opcoes_ssh()])]
        argv += [f"--include={i}" for i in t.incluir]
        argv += [f"--exclude={e}" for e in t.excluir]
        argv += [origem, destino]
        return self._rodar(argv, None, saida, True)

    def fechar(self) -> None:
        """Encerra o mestre (ssh -O exit); nunca levanta."""
        try:
            self._executar(
                ["ssh", *self.opcoes_ssh(), "-O", "exit", self.alias], 15, None
            )
        except Exception:
            pass
