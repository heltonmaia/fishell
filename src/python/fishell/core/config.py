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


TIPOS = ("local", "slurm")


class ErroConfig(ValueError):
    """destinos.toml inválido; a mensagem cabe numa linha e cita o arquivo."""


def dir_config() -> Path:
    env = os.environ.get("FISHELL_CONFIG_DIR")
    return Path(env) if env else Path.home() / ".config" / "fishell"


def dir_estado() -> Path:
    env = os.environ.get("FISHELL_STATE_DIR")
    return Path(env) if env else Path.home() / ".local" / "state" / "fishell"


def _textos(valor: object) -> bool:
    return isinstance(valor, list) and all(isinstance(v, str) for v in valor)


def _destino(d: object, i: int) -> DestinoConfig:
    if not isinstance(d, dict):
        raise ValueError("`destino` deve ser uma lista de tabelas [[destino]]")
    nome = d.get("nome")
    if not isinstance(nome, str) or not nome:
        raise ValueError(f"o {i}º [[destino]] não tem `nome`")
    if "tipo" not in d:
        raise ValueError(f"destino {nome!r} não tem `tipo` (use {' ou '.join(TIPOS)})")
    tipo = d["tipo"]
    if tipo not in TIPOS:
        raise ValueError(f"destino {nome!r}: tipo desconhecido {tipo!r} (use {' ou '.join(TIPOS)})")
    ssh = d.get("ssh")
    if ssh is not None and not isinstance(ssh, str):
        raise ValueError(f"destino {nome!r}: `ssh` deve ser texto")
    particoes = d.get("particoes", [])
    if not _textos(particoes):
        raise ValueError(f"destino {nome!r}: `particoes` deve ser uma lista de textos")
    return DestinoConfig(nome=nome, tipo=tipo, ssh=ssh, particoes=tuple(particoes))


def ler_config(dir_cfg: Path | None = None) -> Config:
    """Lê o destinos.toml; sem ele, os destinos padrão. Inválido: ErroConfig.

    Uma lista de [[destino]] substitui os padrão por inteiro (inclusive o local).
    """
    arquivo = (dir_cfg if dir_cfg is not None else dir_config()) / "destinos.toml"
    if not arquivo.is_file():
        return Config(PADRAO, ())
    try:
        try:
            dados = tomllib.loads(arquivo.read_text(encoding="utf-8"))
        except (tomllib.TOMLDecodeError, UnicodeDecodeError, OSError) as e:
            raise ValueError(f"TOML inválido: {e}") from e
        projetos = dados.get("projetos", [])
        if not _textos(projetos):
            raise ValueError("`projetos` deve ser uma lista de textos")
        lista = dados.get("destino", [])
        if not isinstance(lista, list):
            raise ValueError("`destino` deve ser uma lista de tabelas [[destino]]")
        destinos = tuple(_destino(d, i) for i, d in enumerate(lista, 1))
        nomes = [d.nome for d in destinos]
        repetidos = sorted({n for n in nomes if nomes.count(n) > 1})
        if repetidos:
            raise ValueError(f"destino repetido: {', '.join(repetidos)}")
    except ValueError as e:
        detalhe = " ".join(str(e).split())
        raise ErroConfig(f"{arquivo}: {detalhe}") from e
    return Config(destinos or PADRAO, tuple(Path(p).expanduser() for p in projetos))


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
