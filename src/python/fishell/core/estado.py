"""Registro local dos jobs submetidos (SQLite)."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .modelos import TERMINAIS, EstadoJob


@dataclass(frozen=True)
class RegistroJob:
    destino: str
    job_id: str
    projeto: str
    nome: str
    log: str | None
    array_total: int | None
    inicio: datetime
    estado: EstadoJob
    notificado: bool


_SQL = """
CREATE TABLE IF NOT EXISTS jobs (
    destino TEXT NOT NULL, job_id TEXT NOT NULL, projeto TEXT NOT NULL,
    nome TEXT NOT NULL, log TEXT, array_total INTEGER,
    inicio TEXT NOT NULL, estado TEXT NOT NULL, notificado INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (destino, job_id)
)
"""
_COLS = "destino, job_id, projeto, nome, log, array_total, inicio, estado, notificado"


def _registro(l: tuple) -> RegistroJob:
    return RegistroJob(
        l[0], l[1], l[2], l[3], l[4], l[5],
        datetime.fromisoformat(l[6]), EstadoJob(l[7]), bool(l[8]),
    )


class Estado:
    def __init__(self, arquivo: Path):
        self.arquivo = Path(arquivo)
        self.arquivo.parent.mkdir(parents=True, exist_ok=True)
        with self._con() as con:
            con.execute(_SQL)

    def _con(self) -> sqlite3.Connection:
        con = sqlite3.connect(self.arquivo)
        con.execute("PRAGMA busy_timeout = 5000")
        return con

    def registrar(self, destino, job_id, projeto, nome, log, array_total) -> None:
        with self._con() as con:
            con.execute(
                f"INSERT OR IGNORE INTO jobs ({_COLS}) VALUES (?,?,?,?,?,?,?,?,0)",
                (destino, job_id, projeto, nome, log, array_total,
                 datetime.now().isoformat(), EstadoJob.FILA.value),
            )

    def ativos(self, destino: str | None = None) -> list[RegistroJob]:
        terminais = [e.value for e in TERMINAIS]
        sql = f"SELECT {_COLS} FROM jobs WHERE estado NOT IN ({','.join('?' * len(terminais))})"
        args: list = list(terminais)
        if destino is not None:
            sql += " AND destino = ?"
            args.append(destino)
        with self._con() as con:
            return [_registro(l) for l in con.execute(sql + " ORDER BY inicio", args)]

    def recentes(self, destino: str, desde: datetime) -> list[RegistroJob]:
        with self._con() as con:
            linhas = con.execute(
                f"SELECT {_COLS} FROM jobs WHERE destino = ? AND inicio >= ? ORDER BY inicio",
                (destino, desde.isoformat()),
            )
            return [_registro(l) for l in linhas]

    def atualizar(self, destino: str, job_id: str, estado: EstadoJob) -> bool:
        """True só na primeira vez que o job chega a um estado terminal."""
        with self._con() as con:
            linha = con.execute(
                "SELECT estado FROM jobs WHERE destino = ? AND job_id = ?", (destino, job_id)
            ).fetchone()
            if linha is None:
                return False
            antes = EstadoJob(linha[0])
            con.execute(
                "UPDATE jobs SET estado = ? WHERE destino = ? AND job_id = ?",
                (estado.value, destino, job_id),
            )
            return estado in TERMINAIS and antes not in TERMINAIS

    def marcar_notificado(self, destino: str, job_id: str) -> None:
        with self._con() as con:
            con.execute(
                "UPDATE jobs SET notificado = 1 WHERE destino = ? AND job_id = ?",
                (destino, job_id),
            )
