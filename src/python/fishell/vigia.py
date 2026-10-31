"""Vigia: processo curto que avisa quando um job termina."""

from __future__ import annotations

import fcntl
import shutil
import subprocess
import sys
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from . import textos
from .core.config import dir_estado
from .core.estado import Estado
from .core.hub import Hub


def rodar_vigia(
    hub: Hub,
    estado: Estado,
    notificar: Callable[[str, str], None],
    dormir: Callable[[float], None],
    agora: Callable[[], datetime] = datetime.now,
) -> int:
    while True:
        visao = hub.atualizar()
        for r in estado.pendentes_de_aviso():
            notificar(
                textos.VIGIA_TITULO,
                textos.VIGIA_TERMINOU.format(nome=r.nome, estado=r.estado.value),
            )
            estado.marcar_notificado(r.destino, r.job_id)
        ativos = {r.destino for r in estado.ativos()}
        for destino in sorted(ativos & visao.sem_acesso):
            notificar(textos.VIGIA_TITULO, textos.VIGIA_PAROU.format(destino=destino))
            return 1
        if not ativos and not estado.pendentes_de_aviso():
            return 0
        agora_ = agora()
        esperas = []
        for d in ativos:
            if d not in hub.adaptadores:
                continue
            ate = visao.indisponivel_ate.get(d)
            if ate is not None and ate > agora_:
                esperas.append((ate - agora_).total_seconds())
            else:
                esperas.append(hub.adaptadores[d].intervalo)
        espera = min(esperas, default=3.0)
        dormir(max(espera, 1.0))


def pegar_lock(dir_est: Path):
    """Lock não bloqueante do vigia; devolve o arquivo aberto, ou None se ocupado."""
    dir_est.mkdir(parents=True, exist_ok=True)
    f = open(dir_est / "vigia.lock", "a+")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close()
        return None
    return f


def garantir_vigia(dir_est: Path) -> None:
    f = pegar_lock(dir_est)
    if f is None:
        return
    f.close()  # solta o lock: o processo novo o pega
    with open(dir_est / "vigia.log", "ab") as log:
        subprocess.Popen(
            [sys.executable, "-m", "fishell", "vigia"],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
        )


def notificar_desktop(titulo: str, corpo: str) -> None:
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "fishell", titulo, corpo], check=False)
        return
    destino = dir_estado()
    destino.mkdir(parents=True, exist_ok=True)
    with open(destino / "vigia.log", "a") as f:
        f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {titulo}: {corpo}\n")
