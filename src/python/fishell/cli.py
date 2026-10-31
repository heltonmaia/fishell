import argparse
import time

from fishell import __version__, textos, vigia
from fishell.core.config import dir_estado
from fishell.core.hub import Hub
from fishell.core.montagem import montar_hub

_lock_vigia = None  # mantido aberto pelo tempo de vida do processo


def _hub() -> Hub:
    return montar_hub(iniciar_vigia=lambda: vigia.garantir_vigia(dir_estado()))


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="fishell", description=textos.DESCRICAO)
    p.add_argument("--version", action="version", version=f"fishell {__version__}")
    sub = p.add_subparsers(dest="comando")
    sub.add_parser("vigia", help=textos.AJUDA_VIGIA)
    return p


def _vigia() -> int:
    global _lock_vigia
    _lock_vigia = vigia.pegar_lock(dir_estado())
    if _lock_vigia is None:
        return 0
    hub = montar_hub()  # sem iniciar_vigia: o vigia não se dispara
    return vigia.rodar_vigia(hub, hub.estado, vigia.notificar_desktop, time.sleep)


def main(argv: list[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 0
    if args.comando == "vigia":
        return _vigia()
    return 0
