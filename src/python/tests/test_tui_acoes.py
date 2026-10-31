from pathlib import Path

from textual.widgets import Button, Checkbox, DataTable, Input, RichLog, Select

from fishell import textos
from fishell.core.estado import Estado
from fishell.core.hub import Hub
from fishell.core.modelos import EstadoJob, Job, Receita, Recurso, SecaoReceita
from fishell.tui.acoes import ConfirmarScreen, NovoJobScreen, TrazerScreen
from fishell.tui.app import FishellApp
from tests.fakes import AdaptadorFalso

SEM_ENVIO = frozenset({"ambiente", "submeter", "cancelar", "log"})


def _secao(destino, **kw):
    base = dict(
        destino=destino, remoto=None, enviar=(), trazer=(), ambiente=None,
        job=None, submeter=None, comando=None, particao=None, log=None,
    )
    base.update(kw)
    return SecaoReceita(**base)


def _receita(nome="pose", erro=None):
    secoes = {
        "npad": _secao("npad", job="job.sh", particao="gpu-4-a100", log="l.out"),
        "local": _secao("local", comando="python x.py"),
    }
    return Receita(Path("/p"), nome, secoes, erro)


def _hub(tmp_path, atraso=0.0, receitas=None, jobs=None):
    npad = AdaptadorFalso(
        nome="npad",
        atraso=atraso,
        jobs=jobs if jobs is not None else [
            Job("npad", "1", "kp", EstadoJob.RODANDO, projeto="pose"),
            Job("npad", "2", "ext", EstadoJob.FILA),
        ],
        recursos=[Recurso("gpu-4-a100", 1, 2), Recurso("gpu-2-h200", 0, 2)],
    )
    local = AdaptadorFalso(nome="local", capacidades=SEM_ENVIO)
    rs = receitas if receitas is not None else [_receita()]
    return Hub({"npad": npad, "local": local}, Estado(tmp_path / "e.db"), rs)


async def _esperar(app, pilot):
    await pilot.pause()
    for _ in range(500):
        await app.workers.wait_for_complete()
        if not app.em_fundo():
            break
        await pilot.pause(0.01)
    await pilot.pause()


async def _abrir_modal(app, pilot):
    await _esperar(app, pilot)
    await pilot.press("n")
    await pilot.pause()
    assert isinstance(app.screen, NovoJobScreen)
    return app.screen


async def _escolher(tela, pilot, projeto="pose", destino="npad"):
    tela.query_one("#projeto", Select).value = projeto
    await pilot.pause()
    tela.query_one("#destino", Select).value = destino
    await pilot.pause()


def _chamadas(hub, destino, nome):
    return [c for c in hub.adaptadores[destino].chamadas if c[0] == nome]


async def test_submeter_pelo_modal(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        opcoes = [str(p) for p, _ in tela.query_one("#particao", Select)._options]
        assert any("gpu-4-a100  livres 1/2" in o for o in opcoes)
        assert any("gpu-2-h200  livres 0/2" in o for o in opcoes)
        tela.query_one("#particao", Select).value = "gpu-4-a100"
        tela.query_one("#array", Input).value = "1-65%16"
        await pilot.pause()
        tela.query_one("#submeter", Button).press()
        await _esperar(app, pilot)
        [(_, (receita, particao, array, _saida))] = _chamadas(hub, "npad", "submeter")
        assert (receita.nome, particao, array) == ("pose", "gpu-4-a100", "1-65%16")
        assert len(_chamadas(hub, "npad", "enviar")) == 1  # enviar antes marcado
        assert isinstance(app.screen, NovoJobScreen)  # continua aberto
        linhas = [l.text for l in tela.query_one(RichLog).lines]
        assert linhas[-1] == textos.ACAO_SUBMETIDO.format(job="999")


async def test_enviar_antes_desmarcado(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        tela.query_one("#enviar-antes", Checkbox).value = False
        await pilot.pause()
        tela.query_one("#submeter", Button).press()
        await _esperar(app, pilot)
        assert _chamadas(hub, "npad", "enviar") == []
        assert len(_chamadas(hub, "npad", "submeter")) == 1


async def test_array_invalido_bloqueia(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        tela.query_one("#array", Input).value = "65"
        await pilot.pause()
        tela.query_one("#submeter", Button).press()
        await _esperar(app, pilot)
        assert _chamadas(hub, "npad", "submeter") == []
        linhas = [l.text for l in tela.query_one(RichLog).lines]
        assert textos.ACAO_ARRAY_INVALIDO in linhas
        assert not tela.query_one("#submeter", Button).disabled


async def test_local_sem_enviar_trazer_particao_nem_array(tmp_path):
    app = FishellApp(_hub(tmp_path))
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot, destino="local")
        assert not tela.query_one("#enviar", Button).display
        assert not tela.query_one("#trazer", Button).display
        assert tela.query_one("#ambiente", Button).display
        assert not tela.query_one("#particao", Select).display
        assert not tela.query_one("#array", Input).display
        assert not tela.query_one("#enviar-antes", Checkbox).display
        await _escolher(tela, pilot, destino="npad")
        assert tela.query_one("#enviar", Button).display
        assert tela.query_one("#particao", Select).display
        assert tela.query_one("#array", Input).display


async def test_enviar_trazer_e_ambiente(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        for bid in ("enviar", "trazer", "ambiente"):
            tela.query_one(f"#{bid}", Button).press()
            await _esperar(app, pilot)
        assert [c[0] for c in hub.adaptadores["npad"].chamadas if c[0] in
                ("enviar", "trazer", "montar_ambiente")] == ["enviar", "trazer", "montar_ambiente"]
        linhas = [l.text for l in tela.query_one(RichLog).lines]
        assert textos.ACAO_OK in linhas
        assert textos.ACAO_CODIGO.format(codigo=0) in linhas


async def test_projeto_com_erro_desabilita_acoes(tmp_path):
    hub = _hub(tmp_path, receitas=[_receita("ruim", erro="receita quebrada")])
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot, projeto="ruim")
        assert tela.query_one("#submeter", Button).disabled
        linhas = [l.text for l in tela.query_one(RichLog).lines]
        assert any("receita quebrada" in l for l in linhas)


async def test_erro_do_hub_vai_ao_log_e_notifica(tmp_path):
    hub = _hub(tmp_path)

    def quebra(*a, **k):
        raise ValueError("sem rota")

    hub.submeter = quebra
    app = FishellApp(hub)
    avisos = []
    app.notify = lambda msg, **kw: avisos.append(msg)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        tela.query_one("#submeter", Button).press()
        await _esperar(app, pilot)
        assert app.is_running and isinstance(app.screen, NovoJobScreen)
        linhas = [l.text for l in tela.query_one(RichLog).lines]
        assert textos.ACAO_ERRO.format(erro="sem rota") in linhas
        assert any("sem rota" in a for a in avisos)


async def test_botoes_desabilitados_durante_a_acao(tmp_path):
    hub = _hub(tmp_path, atraso=1.0)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        tela.query_one("#enviar", Button).press()
        await pilot.pause(0.3)
        assert tela.query_one("#enviar", Button).disabled
        assert tela.query_one("#submeter", Button).disabled
        await _esperar(app, pilot)
        assert not tela.query_one("#enviar", Button).disabled
        assert len(_chamadas(hub, "npad", "enviar")) == 1


async def test_enviar_longo_nao_bloqueia_atualizacao(tmp_path):
    hub = _hub(tmp_path, atraso=3.0)
    contagem = []
    original = hub.atualizar_destino
    hub.atualizar_destino = lambda nome, forcar=False: (contagem.append(1), original(nome, forcar))[1]
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        antes = len(contagem)
        tela.query_one("#enviar", Button).press()
        await pilot.pause(2.5)
        assert len(contagem) > antes
        await _esperar(app, pilot)


async def test_tab_e_enter_inativos_em_modal(tmp_path):
    app = FishellApp(_hub(tmp_path))
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        assert app.check_action("alternar_foco", ()) is True
        tela = await _abrir_modal(app, pilot)
        assert app.check_action("alternar_foco", ()) is False
        assert app.check_action("abrir_log", ()) is False
        await pilot.pause()
        antes = app.focused
        await pilot.press("tab")
        await pilot.pause()
        assert app.focused is not antes  # tab andou pelos campos do modal
        assert isinstance(app.screen, NovoJobScreen)


async def test_rodape_tem_n_m_p_c(tmp_path):
    app = FishellApp(_hub(tmp_path))
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        ativos = app.active_bindings
        for tecla, texto in (
            ("n", textos.TUI_TECLA_NOVO), ("m", textos.TUI_TECLA_MONTAR),
            ("p", textos.TUI_TECLA_TRAZER), ("c", textos.TUI_TECLA_CANCELAR),
        ):
            assert ativos[tecla].binding.description == texto
            assert ativos[tecla].binding.show


async def test_teclas_sem_job_destacado_so_avisam(tmp_path):
    hub = _hub(tmp_path, jobs=[])
    app = FishellApp(hub)
    avisos = []
    app.notify = lambda msg, **kw: avisos.append(msg)
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        for t in "mpc":
            await pilot.press(t)
            await pilot.pause()
        assert avisos == [textos.ACAO_SEM_JOB] * 3
        assert not isinstance(app.screen, (NovoJobScreen, ConfirmarScreen, TrazerScreen))


async def test_m_abre_no_projeto_do_job(tmp_path):
    app = FishellApp(_hub(tmp_path))
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        await pilot.press("m")
        await pilot.pause()
        assert isinstance(app.screen, NovoJobScreen)
        assert app.screen.query_one("#projeto", Select).value == "pose"
        assert app.screen.query_one("#destino", Select).value == "npad"


async def test_p_traz_projeto_do_job(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        await pilot.press("p")
        await _esperar(app, pilot)
        [(_, (receita, _s))] = _chamadas(hub, "npad", "trazer")
        assert receita.nome == "pose"
        assert isinstance(app.screen, TrazerScreen)
        linhas = [l.text for l in app.screen.query_one(RichLog).lines]
        assert linhas[-1] == textos.ACAO_OK


async def test_p_job_externo_avisa(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    avisos = []
    app.notify = lambda msg, **kw: avisos.append(msg)
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        app.query_one("#jobs", DataTable).focus()
        await pilot.press("down")
        await pilot.press("p")
        await pilot.pause()
        assert avisos == [textos.ACAO_JOB_EXTERNO]
        assert _chamadas(hub, "npad", "trazer") == []


async def test_cancelar_pede_confirmacao(tmp_path):
    hub = _hub(tmp_path)
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        await _esperar(app, pilot)
        await pilot.press("c")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmarScreen)
        assert textos.ACAO_CONFIRMAR_CANCELAR.format(nome="kp", destino="npad") in str(
            app.screen.query_one("#pergunta").render()
        )
        app.screen.query_one("#nao", Button).press()
        await _esperar(app, pilot)
        assert _chamadas(hub, "npad", "cancelar") == []
        await pilot.press("c")
        await pilot.pause()
        app.screen.query_one("#sim", Button).press()
        await _esperar(app, pilot)
        assert _chamadas(hub, "npad", "cancelar") == [("cancelar", ("1",))]


# --- F4: ambiente que falha aparece como erro --------------------------
async def test_ambiente_com_codigo_diferente_de_zero_e_erro(tmp_path):
    hub = _hub(tmp_path)
    hub.adaptadores["npad"].codigo_ambiente = 254
    app = FishellApp(hub)
    avisos = []
    app.notify = lambda msg, **kw: avisos.append((msg, kw.get("severity")))
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        tela.query_one("#ambiente", Button).press()
        await _esperar(app, pilot)
        esperado = textos.ACAO_ERRO.format(erro=textos.ACAO_AMBIENTE_FALHOU.format(codigo=254))
        linhas = [l.text for l in tela.query_one(RichLog).lines]
        assert linhas[-1] == esperado
        assert (esperado, "error") in avisos


# --- F7: ação em andamento: o modal fica, sair pergunta e não espera ----
import asyncio
import threading
import time


class _Travado(AdaptadorFalso):
    def __init__(self, soltar, **kw):
        super().__init__(**kw)
        self.soltar = soltar

    def enviar(self, receita, saida):
        self.chamadas.append(("enviar", (receita, saida)))
        self.soltar.wait(10)


def _hub_travado(tmp_path, soltar):
    npad = _Travado(soltar, nome="npad",
                    jobs=[Job("npad", "1", "kp", EstadoJob.RODANDO, projeto="pose")],
                    recursos=[Recurso("gpu-4-a100", 1, 2)])
    local = AdaptadorFalso(nome="local", capacidades=SEM_ENVIO)
    return Hub({"npad": npad, "local": local}, Estado(tmp_path / "e.db"), [_receita()])


async def _comecar_envio(app, pilot):
    tela = await _abrir_modal(app, pilot)
    await _escolher(tela, pilot)
    tela.query_one("#enviar", Button).press()
    for _ in range(200):
        if _chamadas(app.hub, "npad", "enviar"):
            break
        await pilot.pause(0.01)
    assert _chamadas(app.hub, "npad", "enviar")
    return tela


async def test_esc_e_fechar_durante_acao_mantem_o_modal(tmp_path):
    soltar = threading.Event()
    app = FishellApp(_hub_travado(tmp_path, soltar))
    avisos = []
    app.notify = lambda msg, **kw: avisos.append(msg)
    try:
        async with app.run_test(size=(100, 40)) as pilot:
            tela = await _comecar_envio(app, pilot)
            await pilot.press("escape")
            await pilot.pause()
            assert app.screen is tela
            tela.query_one("#fechar", Button).press()
            await pilot.pause()
            assert app.screen is tela
            assert avisos.count(textos.ACAO_EM_ANDAMENTO) == 2
            soltar.set()
            await _esperar(app, pilot)
            await pilot.press("escape")
            await pilot.pause()
            assert not isinstance(app.screen, NovoJobScreen)
    finally:
        soltar.set()


async def test_q_com_acao_em_andamento_pede_confirmacao(tmp_path):
    soltar = threading.Event()
    app = FishellApp(_hub_travado(tmp_path, soltar))
    try:
        async with app.run_test(size=(100, 40)) as pilot:
            tela = await _comecar_envio(app, pilot)
            await pilot.press("q")
            await pilot.pause()
            assert isinstance(app.screen, ConfirmarScreen)
            assert textos.ACAO_SAIR_EM_ANDAMENTO in str(app.screen.query_one("#pergunta").render())
            app.screen.query_one("#nao", Button).press()
            await pilot.pause()
            assert app.screen is tela and app.is_running
            soltar.set()
            await _esperar(app, pilot)
    finally:
        soltar.set()


async def test_sair_nao_espera_acao_travada(tmp_path):
    soltar = threading.Event()
    app = FishellApp(_hub_travado(tmp_path, soltar))
    try:
        async with app.run_test(size=(100, 40)) as pilot:
            await _comecar_envio(app, pilot)
            await pilot.press("q")
            await pilot.pause()
            assert isinstance(app.screen, ConfirmarScreen)
            t0 = time.monotonic()
            app.screen.query_one("#sim", Button).press()
            for _ in range(200):
                if not app.is_running:
                    break
                await asyncio.sleep(0.01)
            assert not app.is_running
        assert time.monotonic() - t0 < 2
        assert not soltar.is_set()  # o envio ainda estava preso quando o app saiu
        presas = [t for t in threading.enumerate() if t.name.startswith("fishell-")]
        assert presas and all(t.daemon for t in presas)
    finally:
        soltar.set()


async def test_q_em_modal_parado_nao_sai(tmp_path):
    app = FishellApp(_hub(tmp_path))
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await pilot.press("q")
        await pilot.pause()
        assert app.is_running and app.screen is tela


# --- F9: partição e array só no modo job ------------------------------
async def test_modo_script_esconde_particao_e_array(tmp_path):
    secoes = {"npad": _secao("npad", submeter="go.sh", log="l.out", particao="gpu-4-a100")}
    hub = _hub(tmp_path, receitas=[Receita(Path("/p"), "pose", secoes)])
    app = FishellApp(hub)
    async with app.run_test(size=(100, 40)) as pilot:
        tela = await _abrir_modal(app, pilot)
        await _escolher(tela, pilot)
        assert not tela.query_one("#particao", Select).display
        assert not tela.query_one("#array", Input).display
        assert tela.query_one("#submeter", Button).display
        tela.query_one("#submeter", Button).press()
        await _esperar(app, pilot)
        [(_, (_r, particao, array, _s))] = _chamadas(hub, "npad", "submeter")
        assert (particao, array) == (None, None)
