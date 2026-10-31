"""Destinos e projetos do usuário (destinos.toml)."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from .modelos import Receita
from .receita import ler_receita


@dataclass(frozen=True)
class DestinoConfig:
    nome: str
    tipo: Literal["local", "slurm"]
    ssh: str | None = None
    particoes: tuple[str, ...] = ()


@dataclass(frozen=True)
class Config:
    destinos: tuple[DestinoConfig, ...]
    projetos: tuple[Path, ...]


PADRAO = (DestinoConfig("local", "local"), DestinoConfig("npad", "slurm", "npad"))


def dir_config() -> Path:
    env = os.environ.get("FISHELL_CONFIG_DIR")
    return Path(env) if env else Path.home() / ".config" / "fishell"


def dir_estado() -> Path:
    env = os.environ.get("FISHELL_STATE_DIR")
    return Path(env) if env else Path.home() / ".local" / "state" / "fishell"


def ler_config(dir_cfg: Path | None = None) -> Config:
    arquivo = (dir_cfg if dir_cfg is not None else dir_config()) / "destinos.toml"
    if not arquivo.is_file():
        return Config(PADRAO, ())
    dados = tomllib.loads(arquivo.read_text(encoding="utf-8"))
    projetos = tuple(Path(p).expanduser() for p in dados.get("projetos", []))
    destinos = tuple(
        DestinoConfig(
            nome=d["nome"],
            tipo=d["tipo"],
            ssh=d.get("ssh"),
            particoes=tuple(d.get("particoes", [])),
        )
        for d in dados.get("destino", [])
    )
    return Config(destinos or PADRAO, projetos)


def descobrir_receitas(cfg: Config, cwd: Path) -> list[Receita]:
    """Receitas dos projetos configurados mais a do cwd, sem repetir."""
    receitas: list[Receita] = []
    vistos: set[Path] = set()
    for raiz in (*cfg.projetos, cwd):
        chave = Path(raiz).resolve()
        if chave in vistos:
            continue
        vistos.add(chave)
        r = ler_receita(raiz)
        if r is not None:
            receitas.append(r)
    return receitas
