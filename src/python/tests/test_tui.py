from datetime import datetime

from textual.widgets import DataTable, OptionList, RichLog

from fishell import cli, textos
from fishell.adapters.base import Indisponivel
from fishell.core.estado import Estado
from fishell.core.hub import Hub
from fishell.core.modelos import EstadoJob, Job, Recurso
from fishell.tui.app import FishellApp, LogScreen
from tests.fakes import AdaptadorFalso


def _hub(tmp_path, *adaptadores):
    return Hub({a.nome: a for a in adaptadores}, Estado(tmp_path / "e.db"), [])


def _prompts(app):
    barra = app.query_one("#destinos", OptionList)
    return " ".join(str(barra.get_option_at_index(i).prompt) for i in range(barra.option_count))


def _celulas(tabela):
    return [tuple(str(c) for c in tabela.get_row_at(i)) for i in range(tabela.row_count)]


async def _esperar(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


def _dois_destinos(tmp_path):
    npad = AdaptadorFalso(
        nome="npad",
        jobs=[
            Job("npad", "1", "kp", EstadoJob.RODANDO, array_total=65, array_ok=47, projeto="pose"),
            Job("npad", "2", "sam", EstadoJob.FILA, projeto="sam"),
        ],
        recursos=[Recurso("a100", 0, 1), Recurso("h200", 0, 2)],
        linhas_log=["linha a", "linha b"],
    )
    local = AdaptadorFalso(
        nome="local",
        jobs=[Job("local", "9", "yolo", EstadoJob.OK, externo=True)],
    )
    return _hub(tmp_path, npad, local)


async def test_mostra_jobs_de_todos_os_destinos(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        tabela = app.query_one("#jobs", DataTable)
        assert tabela.row_count == 3
        assert [str(c.label) for c in tabela.columns.values()] == [
            "DESTINO", "PROJETO", "JOB", "ESTADO", "TEMPO", "LOG",
        ]
        assert any(l[2] == "yolo *" for l in _celulas(tabela))


async def test_filtrar_por_destino(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        app.query_one("#destinos", OptionList).focus()
        await pilot.press("down")
        await _esperar(app, pilot)
        linhas = _celulas(app.query_one("#jobs", DataTable))
        assert len(linhas) == 2
        assert {l[0] for l in linhas} == {"npad"}


async def test_array_mostra_progresso(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        estados = [l[3] for l in _celulas(app.query_one("#jobs", DataTable))]
        assert "● 47/65 ok" in estados
        assert "◌ fila" in estados
        assert "✓ ok" in estados


async def test_aviso_aparece_na_barra(tmp_path):
    ate = datetime(2026, 10, 31, 10, 30)
    app = FishellApp(_hub(tmp_path, AdaptadorFalso(nome="npad", erro=Indisponivel(ate))))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        barra = app.query_one("#destinos", OptionList)
        textos = " ".join(str(barra.get_option_at_index(i).prompt) for i in range(barra.option_count))
        assert "indisponível até 10:30" in textos


async def test_recursos_na_barra(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        barra = app.query_one("#destinos", OptionList)
        textos = " ".join(str(barra.get_option_at_index(i).prompt) for i in range(barra.option_count))
        assert "a100 0/1" in textos and "●" in textos and "◌" in textos


async def test_log_ao_vivo_do_job_destacado(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        await _esperar(app, pilot)
        log = app.query_one("#log", RichLog)
        assert [l.text for l in log.lines] == ["linha a", "linha b"]


async def test_enter_abre_log(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        app.query_one("#jobs", DataTable).focus()
        await pilot.press("enter")
        await _esperar(app, pilot)
        assert isinstance(app.screen, LogScreen)
        assert [l.text for l in app.screen.query_one(RichLog).lines] == ["linha a", "linha b"]
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, LogScreen)


async def test_selecao_estavel_entre_atualizacoes(tmp_path):
    hub = _dois_destinos(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        tabela = app.query_one("#jobs", DataTable)
        tabela.focus()
        await pilot.press("down")
        antes = _celulas(tabela)[tabela.cursor_row]
        app.atualizar_agora()
        await _esperar(app, pilot)
        assert _celulas(tabela)[tabela.cursor_row] == antes


async def test_log_nao_recarrega_a_cada_tick(tmp_path):
    hub = _dois_destinos(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        await _esperar(app, pilot)
        for _ in range(3):
            app.atualizar_agora()
            await _esperar(app, pilot)
        chamadas = [c for c in hub.adaptadores["npad"].chamadas if c[0] == "log"]
        assert len(chamadas) == 1


async def test_erro_no_hub_vira_aviso_sem_derrubar(tmp_path):
    hub = _dois_destinos(tmp_path)

    def quebra(forcar=False):
        raise RuntimeError("boom")

    hub.atualizar = quebra
    app = FishellApp(hub)
    avisos = []
    app.notify = lambda msg, **kw: avisos.append((msg, kw))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        assert app.is_running
        assert avisos and "boom" in avisos[0][0]
        assert avisos[0][1].get("severity") == "error"


async def test_erro_no_callback_chega_na_notificacao(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    avisos = []
    app.notify = lambda msg, **kw: avisos.append(msg)

    def quebra(visao):
        raise ValueError("cb")

    app._aplicar = quebra
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        assert any("cb" in a for a in avisos)


async def test_chamada_apos_sair_nao_levanta(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
    app._na_principal(lambda: None)


async def test_footer_tem_enter_log_cheio(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        ativos = app.active_bindings
        assert ativos["enter"].binding.description == textos.TUI_TECLA_LOG
        assert ativos["enter"].binding.show
        assert "tab" in ativos and "q" in ativos


async def test_recurso_com_texto_leva_rotulo(tmp_path):
    ad = AdaptadorFalso(nome="local", recursos=[Recurso("RTX 5060 Ti", texto="0% 1/16G")])
    app = FishellApp(_hub(tmp_path, ad))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        assert "RTX 5060 Ti 0% 1/16G" in _prompts(app)


async def test_recursos_uma_por_linha_gpu_primeiro(tmp_path):
    ad = AdaptadorFalso(
        nome="npad",
        recursos=[
            Recurso("amd-512", 11, 56),
            Recurso("amd-3tb", 1, 4),
            Recurso("gpu-4-a100", 0, 1),
            Recurso("gpu-2-h200", 0, 2),
        ],
    )
    app = FishellApp(_hub(tmp_path, ad))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        barra = app.query_one("#destinos", OptionList)
        linhas = str(barra.get_option_at_index(1).prompt).split("\n")
        assert linhas == ["npad", "a100 0/1", "h200 0/2", "amd-512 11/56"]


async def test_aviso_substitui_recursos(tmp_path):
    ate = datetime(2026, 10, 31, 10, 30)
    ad = AdaptadorFalso(nome="npad", erro=Indisponivel(ate))
    app = FishellApp(_hub(tmp_path, ad))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        barra = app.query_one("#destinos", OptionList)
        assert str(barra.get_option_at_index(1).prompt).split("\n")[1] == "indisponível até 10:30"


async def test_tabela_nao_reconstroi_sem_mudanca(tmp_path):
    app = FishellApp(_dois_destinos(tmp_path))
    async with app.run_test(size=(100, 30)) as pilot:
        await _esperar(app, pilot)
        tabela = app.query_one("#jobs", DataTable)
        n = []
        original = tabela.clear
        tabela.clear = lambda *a, **k: (n.append(1), original(*a, **k))[1]
        for _ in range(2):
            app.atualizar_agora()
            await _esperar(app, pilot)
        assert n == []


def test_sem_subcomando_abre_a_tela(monkeypatch):
    aberto = []

    class Falso:
        def __init__(self, hub):
            aberto.append(hub)

        def run(self):
            aberto.append("run")

    monkeypatch.setattr(cli, "_hub", lambda: "HUB")
    monkeypatch.setattr(cli, "_abrir_tela", lambda hub: Falso(hub).run())
    assert cli.main([]) == 0
    assert aberto == ["HUB", "run"]
    aberto.clear()
    assert cli.main(["menu"]) == 0
    assert aberto == ["HUB", "run"]


def test_cli_nao_carrega_textual_no_import():
    import subprocess
    import sys

    r = subprocess.run(
        [sys.executable, "-c", "import sys, fishell.cli; print('textual' in sys.modules)"],
        capture_output=True, text=True,
    )
    assert r.stdout.strip() == "False"
