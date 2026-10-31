"""Monta o Hub a partir da configuração do usuário."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from ..adapters.base import Adaptador
from ..adapters.conexao import Conexao
from ..adapters.local import AdaptadorLocal
from ..adapters.slurm import AdaptadorSlurm
from .config import descobrir_receitas, dir_config, dir_estado, ler_config
from .estado import Estado
from .hub import Hub, _nada


def montar_hub(
    dir_cfg: Path | None = None,
    dir_est: Path | None = None,
    cwd: Path | None = None,
    iniciar_vigia: Callable[[], None] | None = None,
) -> Hub:
    dir_cfg = Path(dir_cfg) if dir_cfg is not None else dir_config()
    dir_est = Path(dir_est) if dir_est is not None else dir_estado()
    cfg = ler_config(dir_cfg)
    estado = Estado(dir_est / "estado.db")
    adaptadores: dict[str, Adaptador] = {}
    for d in cfg.destinos:
        if d.tipo == "local":
            adaptadores[d.nome] = AdaptadorLocal(estado, dir_est / "jobs")
        elif d.tipo == "slurm":
            adaptadores[d.nome] = AdaptadorSlurm(
                d.nome, Conexao(d.ssh or d.nome, dir_est / "ctl"), estado, d.particoes
            )
    receitas = descobrir_receitas(cfg, cwd or Path.cwd())
    return Hub(adaptadores, estado, receitas, iniciar_vigia=iniciar_vigia or _nada)
