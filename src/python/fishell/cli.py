import argparse
import sys
import time

from fishell import __version__, textos, vigia
from fishell.core.config import ErroConfig, dir_estado
from fishell.core.hub import Hub
from fishell.core.montagem import montar_hub
from fishell.formato import linha_job

_lock_vigia = None  # mantido aberto pelo tempo de vida do processo


def _hub() -> Hub:
    return montar_hub(iniciar_vigia=lambda: vigia.garantir_vigia(dir_estado()))


def _abrir_tela(hub: Hub) -> None:
    from fishell.tui.app import FishellApp  # só aqui: o vigia não carrega a interface

    FishellApp(hub).run()


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="fishell", description=textos.DESCRICAO)
    p.add_argument("--version", action="version", version=f"fishell {__version__}")
    sub = p.add_subparsers(dest="comando")
    sub.add_parser("vigia", help=textos.AJUDA_VIGIA)
    sub.add_parser("menu", help=textos.AJUDA_MENU)
    sub.add_parser("jobs", help=textos.AJUDA_JOBS)
    return p


def _vigia() -> int:
    global _lock_vigia
    _lock_vigia = vigia.pegar_lock(dir_estado())
    if _lock_vigia is None:
        return 0
    hub = montar_hub()  # sem iniciar_vigia: o vigia não se dispara
    return vigia.rodar_vigia(hub, hub.estado, vigia.notificar_desktop, time.sleep)


def _jobs() -> int:
    hub = _hub()
    visao = hub.atualizar(forcar=True)
    for celulas in (textos.TUI_COLUNAS, *(linha_job(j) for j in visao.jobs)):
        print("  ".join(celulas).rstrip())
    for destino, texto in visao.avisos.items():
        print(textos.JOBS_AVISO.format(destino=destino, texto=texto))
    erro = hub.garantir_vigia_se_preciso()
    if erro is not None:
        print(textos.HUB_VIGIA_NAO_INICIOU.format(erro=erro), file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 0
    try:
        if args.comando == "vigia":
            return _vigia()
        if args.comando == "jobs":
            return _jobs()
        hub = _hub()
    except ErroConfig as e:
        print(textos.ERRO_CONFIG.format(erro=e), file=sys.stderr)
        return 1
    _abrir_tela(hub)
    return 0
