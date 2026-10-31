"""Tela de jobs: destinos, lista de jobs de todos os destinos e log ao vivo."""

from __future__ import annotations

import contextvars
import re
import threading
import time
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Header, OptionList, RichLog
from textual.widgets.option_list import Option

from .. import textos
from .acoes import ConfirmarScreen, NovoJobScreen, TrazerScreen
from ..core.hub import Hub, Visao
from ..core.modelos import EstadoJob, Job
from ..formato import linha_job

LINHAS_LOG = 40
LINHAS_LOG_CHEIO = 400
LARGURA_LINHA = 24
_ACOES_DO_PAINEL = frozenset(
    {"abrir_log", "alternar_foco", "novo_job", "montar", "trazer", "cancelar", "atualizar", "quit"}
)
_ATIVOS = (("●", EstadoJob.RODANDO), ("◌", EstadoJob.FILA))


def _texto_recurso(r) -> str:
    rotulo = re.sub(r"^gpu-\d+-", "", r.rotulo)
    return f"{rotulo} {r.texto}" if r.texto else f"{rotulo} {r.livres}/{r.total}"


def _chave(job: Job) -> str:
    return f"{job.destino}\x00{job.id}"


class LogScreen(Screen):
    BINDINGS = [
        Binding("escape", "voltar", textos.TUI_TECLA_VOLTAR),
        Binding("q", "voltar", show=False),
    ]

    def __init__(self, hub: Hub, job: Job) -> None:
        super().__init__()
        self._hub = hub
        self._job = job

    def compose(self) -> ComposeResult:
        yield Header()
        yield RichLog(id="log-cheio", markup=False, highlight=False)
        yield Footer()

    def on_mount(self) -> None:
        log = self.query_one("#log-cheio", RichLog)
        log.border_title = textos.TUI_LOG_CHEIO.format(destino=self._job.destino, job=self._job.id)
        self.app._em_fundo(self._carregar)

    def _carregar(self) -> None:  # thread de fundo
        try:
            linhas = self._hub.log(self._job, LINHAS_LOG_CHEIO)
        except Exception as e:  # noqa: BLE001
            linhas = [textos.TUI_ERRO_LOG.format(erro=e)]
        self.app._na_principal(self._pintar, linhas)

    def _pintar(self, linhas: list[str]) -> None:
        if not self.is_attached:
            return  # a tela já foi fechada
        log = self.query_one("#log-cheio", RichLog)
        log.clear()
        for linha in linhas:
            log.write(linha)

    def action_voltar(self) -> None:
        self.app.pop_screen()


class FishellApp(App):
    CSS_PATH = Path(__file__).with_name("app.tcss")
    TITLE = textos.TUI_TITULO
    BINDINGS = [
        Binding("tab", "alternar_foco", textos.TUI_TECLA_ALTERNAR, priority=True),
        Binding("enter", "abrir_log", textos.TUI_TECLA_LOG, priority=True),
        Binding("n", "novo_job", textos.TUI_TECLA_NOVO),
        Binding("m", "montar", textos.TUI_TECLA_MONTAR),
        Binding("p", "trazer", textos.TUI_TECLA_TRAZER),
        Binding("c", "cancelar", textos.TUI_TECLA_CANCELAR),
        Binding("r", "atualizar", textos.TUI_TECLA_ATUALIZAR),
        Binding("q", "quit", textos.TUI_TECLA_SAIR),
    ]

    def __init__(self, hub: Hub) -> None:
        super().__init__()
        self.hub = hub
        self._visao = Visao()
        self._filtro: str | None = None  # None = todos
        self._trava_fundo = threading.Lock()
        self._fundo: set[threading.Thread] = set()
        self._acoes: set[threading.Thread] = set()  # enviar, submeter, cancelar...
        self._em_voo: set[str] = set()  # destinos com atualização em andamento
        self._log_chave: str | None = None
        self._log_t = 0.0
        self._linhas: list[tuple] | None = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="corpo"):
            yield OptionList(id="destinos", markup=False)
            yield DataTable(id="jobs", cursor_type="row")
        yield RichLog(id="log", markup=False, highlight=False)
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#destinos", OptionList).border_title = textos.TUI_DESTINOS
        tabela = self.query_one("#jobs", DataTable)
        tabela.add_columns(*textos.TUI_COLUNAS)
        self.query_one("#log", RichLog).can_focus = False
        self.query_one("#log", RichLog).border_title = textos.TUI_LOG_SEM_JOB
        tabela.focus()
        self._montar_destinos()
        self.set_interval(1.0, self.atualizar_agora)
        self.atualizar_agora()
        self._em_fundo(self._garantir_vigia)

    def _garantir_vigia(self) -> None:  # thread de fundo
        # o vigia não sobrevive a um reboot ou logout: o painel o reinicia ao abrir
        try:
            erro = self.hub.garantir_vigia_se_preciso()
        except Exception as e:  # noqa: BLE001 - nada derruba a interface
            erro = e
        if erro is not None:
            self._na_principal(self._aviso, textos.HUB_VIGIA_NAO_INICIOU.format(erro=erro))

    def _aviso(self, mensagem: str) -> None:
        self.notify(mensagem, severity="warning")

    # --- trabalho em segundo plano -------------------------------------
    def _em_fundo(self, fn, *args, acao: bool = False) -> None:
        """Roda fn(*args) numa thread daemon: sair nunca espera por ela.

        As atualizações da tela voltam pela _na_principal. `acao=True` marca
        uma ação do usuário (envio, script, cancelamento): sair pede confirmação.
        """
        contexto = contextvars.copy_context()  # o `self.app` dos widgets vem daqui

        def alvo() -> None:
            try:
                contexto.run(fn, *args)
            except Exception as e:  # noqa: BLE001 - nada derruba a interface
                self._avisar_erro(e)
            finally:
                with self._trava_fundo:
                    self._fundo.discard(threading.current_thread())
                    self._acoes.discard(threading.current_thread())

        t = threading.Thread(target=alvo, daemon=True, name=f"fishell-{fn.__name__}")
        with self._trava_fundo:
            self._fundo.add(t)
            if acao:
                self._acoes.add(t)
        t.start()

    def em_fundo(self) -> bool:
        """Há thread de fundo em andamento (os testes esperam por elas)."""
        with self._trava_fundo:
            return bool(self._fundo)

    def acao_em_andamento(self) -> bool:
        with self._trava_fundo:
            return bool(self._acoes)

    # --- atualização ---------------------------------------------------
    def atualizar_agora(self, forcar: bool = False) -> None:
        """Uma atualização por destino, cada uma na sua thread e com sua trava."""
        for nome in self.hub.adaptadores:
            with self._trava_fundo:
                if nome in self._em_voo:
                    continue
                self._em_voo.add(nome)
            self._em_fundo(self._atualizar, nome, forcar)

    def _atualizar(self, nome: str, forcar: bool) -> None:
        try:
            consultou = self.hub.atualizar_destino(nome, forcar)
        except Exception as e:  # noqa: BLE001 - nada derruba a interface
            self._na_principal(self._falha, textos.TUI_ERRO.format(erro=e))
            return
        finally:
            with self._trava_fundo:
                self._em_voo.discard(nome)
        if consultou:
            self._na_principal(self._aplicar, self.hub.visao())

    def _na_principal(self, fn, *args) -> None:
        if not self.is_running:
            return  # o app já saiu; uma thread de fundo terminou depois
        try:
            self.call_from_thread(fn, *args)
        except RuntimeError as e:
            if not self._saiu(e):
                self._avisar_erro(e)
        except Exception as e:  # noqa: BLE001 - o erro do callback vira aviso
            self._avisar_erro(e)

    def _saiu(self, e: RuntimeError) -> bool:
        return self._loop is None or "not running" in str(e)

    def _avisar_erro(self, e: Exception) -> None:
        try:
            self.call_from_thread(self._falha, textos.TUI_ERRO.format(erro=e))
        except RuntimeError:
            pass  # o app saiu entre uma chamada e a outra

    def _falha(self, mensagem: str) -> None:
        self.notify(mensagem, severity="error")

    def _aplicar(self, visao: Visao) -> None:
        self._visao = visao
        self._montar_destinos()
        self._montar_tabela()
        self._checar_log()

    # --- barra de destinos ---------------------------------------------
    def _prompt_destino(self, nome: str) -> str:
        v = self._visao
        jobs = [j for j in v.jobs if j.destino == nome]
        sinais = "".join(s for s, e in _ATIVOS if any(j.estado == e for j in jobs))
        cabeca = f"{nome}  {sinais}".rstrip()
        aviso = v.avisos.get(nome)
        if aviso:
            baixo = [aviso]
        else:
            rs = sorted(v.recursos.get(nome, []), key=lambda r: "gpu" not in r.rotulo)[:3]
            baixo = [_texto_recurso(r) for r in rs]
        return "\n".join([cabeca, *(b[:LARGURA_LINHA] for b in baixo)])

    def _montar_destinos(self) -> None:
        barra = self.query_one("#destinos", OptionList)
        ids = [None, *self.hub.adaptadores]
        prompts = [f"{textos.TUI_TODOS}  {len(self._visao.jobs)}"]
        prompts += [self._prompt_destino(n) for n in ids[1:]]
        if barra.option_count != len(ids):
            barra.set_options(Option(p, id=i or "") for p, i in zip(prompts, ids))
            barra.highlighted = 0
            return
        for i, p in enumerate(prompts):
            barra.replace_option_prompt_at_index(i, p)

    def on_option_list_option_highlighted(self, ev: OptionList.OptionHighlighted) -> None:
        novo = ev.option.id or None
        if novo == self._filtro:
            return
        self._filtro = novo
        self._montar_tabela()
        self._checar_log()

    # --- tabela --------------------------------------------------------
    def _job_destacado(self) -> Job | None:
        tabela = self.query_one("#jobs", DataTable)
        if tabela.row_count == 0 or not tabela.is_valid_row_index(tabela.cursor_row):
            return None
        chave = tabela.coordinate_to_cell_key((tabela.cursor_row, 0)).row_key.value
        for j in self._visao.jobs:
            if _chave(j) == chave:
                return j
        return None

    def _montar_tabela(self) -> None:
        linhas = [
            (_chave(j), linha_job(j))
            for j in self._visao.jobs
            if self._filtro is None or j.destino == self._filtro
        ]
        if linhas == self._linhas:
            return
        self._linhas = linhas
        tabela = self.query_one("#jobs", DataTable)
        atual = self._job_destacado()
        tabela.clear()
        for chave, celulas in linhas:
            tabela.add_row(*celulas, key=chave)
        if atual is not None:
            try:
                tabela.move_cursor(row=tabela.get_row_index(_chave(atual)))
            except Exception:  # noqa: BLE001 - o job sumiu da lista
                pass

    def on_data_table_row_highlighted(self, ev: DataTable.RowHighlighted) -> None:
        self._checar_log()

    def check_action(self, action: str, parameters) -> bool | None:
        # só a tela de jobs usa as teclas do app; no resto (modais, log cheio) o
        # tab/enter são do campo e as ações do próprio Textual (focus_next) seguem
        if len(self.screen_stack) > 1:
            if action == "quit":
                # só o ctrl+q (prioritário) chega aqui de um modal; o q do modal é
                # do SaidaScreen. Vale só com ação rodando, que não deixa fechá-lo
                return self.acao_em_andamento() and not isinstance(self.screen, ConfirmarScreen)
            if action in _ACOES_DO_PAINEL:
                return False
        return True

    async def action_quit(self) -> None:
        self.pedir_saida()

    def pedir_saida(self) -> None:
        """Sai já; com ação em andamento, pergunta antes (e sai sem esperá-la)."""
        if not self.acao_em_andamento():
            self.exit()
            return
        self.push_screen(
            ConfirmarScreen(textos.ACAO_SAIR_EM_ANDAMENTO),
            lambda sim: self.exit() if sim else None,
        )

    def action_abrir_log(self) -> None:
        job = self._job_destacado()
        if job is not None:
            self.push_screen(LogScreen(self.hub, job))

    # --- ações ---------------------------------------------------------
    def _com_job(self) -> Job | None:
        job = self._job_destacado()
        if job is None:
            self.notify(textos.ACAO_SEM_JOB)
        return job

    def _receita_do_job(self, job: Job) -> bool:
        r = next((r for r in self._visao.receitas if r.nome == job.projeto), None)
        if job.projeto is None or r is None or job.destino not in r.secoes:
            self.notify(textos.ACAO_JOB_EXTERNO)
            return False
        return True

    def action_novo_job(self) -> None:
        self.push_screen(NovoJobScreen(self.hub, self._visao))

    def action_montar(self) -> None:
        job = self._com_job()
        if job is not None and self._receita_do_job(job):
            self.push_screen(NovoJobScreen(self.hub, self._visao, job.projeto, job.destino))

    def action_trazer(self) -> None:
        job = self._com_job()
        if job is not None and self._receita_do_job(job):
            self.push_screen(TrazerScreen(self.hub, job.projeto, job.destino))

    def action_cancelar(self) -> None:
        job = self._com_job()
        if job is None:
            return
        pergunta = textos.ACAO_CONFIRMAR_CANCELAR.format(nome=job.nome, destino=job.destino)
        self.push_screen(ConfirmarScreen(pergunta), lambda sim: self._cancelar(job) if sim else None)

    def _cancelar(self, job: Job) -> None:
        self._em_fundo(self._rodar_cancelar, job, acao=True)

    def _rodar_cancelar(self, job: Job) -> None:  # thread de fundo
        try:
            self.hub.cancelar(job.destino, job.id)
        except Exception as e:  # noqa: BLE001
            self._na_principal(self._falha, textos.ACAO_ERRO.format(erro=e))
        else:
            self._na_principal(self.notify, textos.ACAO_CANCELADO.format(nome=job.nome, destino=job.destino))
            self._na_principal(self.atualizar_agora)

    # --- log ao vivo ---------------------------------------------------
    def _checar_log(self) -> None:
        job = self._job_destacado()
        log = self.query_one("#log", RichLog)
        if job is None:
            self._log_chave = None
            log.clear()
            log.border_title = textos.TUI_LOG_SEM_JOB
            return
        chave = _chave(job)
        ad = self.hub.adaptadores.get(job.destino)
        intervalo = ad.intervalo if ad is not None else 60.0
        agora = time.monotonic()
        if chave == self._log_chave and agora - self._log_t < intervalo:
            return
        if chave != self._log_chave:
            log.clear()
        self._log_chave = chave
        self._log_t = agora
        log.border_title = textos.TUI_LOG_TITULO.format(destino=job.destino, job=job.id)
        self._em_fundo(self._carregar_log, job, chave)

    def _carregar_log(self, job: Job, chave: str) -> None:  # thread de fundo
        try:
            linhas = self.hub.log(job, LINHAS_LOG)
        except Exception as e:  # noqa: BLE001
            linhas = [textos.TUI_ERRO_LOG.format(erro=e)]
        self._na_principal(self._pintar_log, chave, linhas)

    def _pintar_log(self, chave: str, linhas: list[str]) -> None:
        if chave != self._log_chave:
            return
        log = self.query_one("#log", RichLog)
        log.clear()
        for linha in linhas:
            log.write(linha)

    # --- teclas --------------------------------------------------------
    def action_atualizar(self) -> None:
        # forçado: ignora o intervalo e volta a tentar um destino parado por
        # falha de autenticação (o bloqueio de recusa continua valendo)
        self.atualizar_agora(forcar=True)

    def action_alternar_foco(self) -> None:
        barra = self.query_one("#destinos", OptionList)
        if barra.has_focus:
            self.query_one("#jobs", DataTable).focus()
        else:
            barra.focus()
