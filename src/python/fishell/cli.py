import argparse

from fishell import __version__, textos


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="fishell", description=textos.DESCRICAO)
    p.add_argument("--version", action="version", version=f"fishell {__version__}")
    p.add_subparsers(dest="comando")
    return p


def main(argv: list[str] | None = None) -> int:
    try:
        _parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 0
    return 0
