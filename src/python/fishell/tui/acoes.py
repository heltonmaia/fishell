"""Telas modais das ações: novo job, trazer resultados e confirmação."""

from __future__ import annotations

import re
from collections.abc import Callable

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Input, Label, RichLog, Select

from .. import textos
from ..core.hub import Hub, Visao
from ..core.modelos import Receita, SecaoReceita

_ARRAY = re.compile(r"^\d+-\d+(%\d+)?$")
_BOTOES = (
    ("enviar", "enviar", textos.ACAO_BOTAO_ENVIAR),
    ("ambiente", "ambiente", textos.ACAO_BOTAO_AMBIENTE),
    ("submeter", "submeter", textos.ACAO_BOTAO_SUBMETER),
    ("trazer", "trazer", textos.ACAO_BOTAO_TRAZER),
)


class ConfirmarScreen(ModalScreen[bool]):
    BINDINGS = [Binding("escape", "recusar", show=False)]

    def __init__(self, pergunta: str) -> None:
        super().__init__()
        self._pergunta = pergunta

    def compose(self) -> ComposeResult:
        with Vertical(classes="caixa"):
            yield Label(self._pergunta, id="pergunta")
            with Horizontal(classes="botoes"):
                yield Button(textos.ACAO_SIM, id="sim", variant="error")
                yield Button(textos.ACAO_NAO, id="nao", variant="primary")

    @on(Button.Pressed, "#sim")
    def _sim(self) -> None:
        self.dismiss(True)

    @on(Button.Pressed, "#nao")
    def _nao(self) -> None:
        self.dismiss(False)

    def action_recusar(self) -> None:
        self.dismiss(False)


class SaidaScreen(ModalScreen):
    """Base: um RichLog e a execução de uma ação por vez numa thread."""

    BINDINGS = [Binding("escape", "fechar", show=False)]

    def __init__(self, hub: Hub) -> None:
        super().__init__()
        self._hub = hub
        self._ocupado = False

    def action_fechar(self) -> None:
        self.dismiss()

    # chamado na thread de trabalho
    def _linha_de_fora(self, texto: str) -> None:
        self.app._na_principal(self._linha, texto)

    def _linha(self, texto: str) -> None:
        if not self.is_attached:
            return
        self.query_one("#saida", RichLog).write(texto)

    def _estado_ocupado(self, ocupado: bool) -> None:
        self._ocupado = ocupado
        self._atualizar_botoes()

    def _atualizar_botoes(self) -> None:
        pass

    def _iniciar(self, titulo: str, fn: Callable[[Callable[[str], None]], str | None]) -> None:
        """Roda fn(saida) numa thread; o texto devolvido vira a linha final."""
        if self._ocupado:
            return
        self._estado_ocupado(True)
        self._linha(textos.ACAO_EXECUTANDO.format(acao=titulo))
        self._rodar(fn)

    @work(thread=True, group="acao")
    def _rodar(self, fn: Callable[[Callable[[str], None]], str | None]) -> None:
        try:
            final = fn(self._linha_de_fora) or textos.ACAO_OK
            erro = None
        except Exception as e:  # noqa: BLE001 - qualquer falha vai ao log, nunca derruba
            final = textos.ACAO_ERRO.format(erro=e)
            erro = e
        self.app._na_principal(self._terminou, final, erro)

    def _terminou(self, final: str, erro: Exception | None) -> None:
        if self.is_attached:
            self._linha(final)
            self._estado_ocupado(False)
        if erro is not None:
            self.app.notify(textos.ACAO_ERRO.format(erro=erro), severity="error")


class TrazerScreen(SaidaScreen):
    def __init__(self, hub: Hub, projeto: str, destino: str) -> None:
        super().__init__(hub)
        self._projeto = projeto
        self._destino = destino

    def compose(self) -> ComposeResult:
        with Vertical(classes="caixa"):
            yield RichLog(id="saida", markup=False, highlight=False)
            with Horizontal(classes="botoes"):
                yield Button(textos.ACAO_BOTAO_FECHAR, id="fechar")

    def on_mount(self) -> None:
        self.query_one("#saida", RichLog).border_title = textos.ACAO_TITULO_TRAZER.format(
            projeto=self._projeto, destino=self._destino
        )
        self._iniciar(
            textos.ACAO_BOTAO_TRAZER,
            lambda saida: self._hub.trazer(self._projeto, self._destino, saida),
        )

    @on(Button.Pressed, "#fechar")
    def _fechar(self) -> None:
        self.dismiss()


class NovoJobScreen(SaidaScreen):
    def __init__(
        self, hub: Hub, visao: Visao, projeto: str | None = None, destino: str | None = None
    ) -> None:
        super().__init__(hub)
        self._visao = visao
        self._projeto0 = projeto
        self._destino0 = destino

    # --- composição ----------------------------------------------------
    def compose(self) -> ComposeResult:
        opcoes = []
        for r in self._visao.receitas:
            rotulo = (
                textos.ACAO_PROJETO_COM_ERRO.format(nome=r.nome, erro=r.erro) if r.erro else r.nome
            )
            opcoes.append((rotulo, r.nome))
        with Vertical(classes="caixa largo"):
            yield Select(opcoes, prompt=textos.ACAO_PROJETO, id="projeto")
            yield Select([], prompt=textos.ACAO_DESTINO, id="destino")
            yield Select([], prompt=textos.ACAO_PARTICAO, id="particao")
            yield Input(placeholder=textos.ACAO_ARRAY, id="array")
            yield Checkbox(textos.ACAO_ENVIAR_ANTES, True, id="enviar-antes")
            with Horizontal(classes="botoes"):
                for bid, _cap, rotulo in _BOTOES:
                    yield Button(rotulo, id=bid)
                yield Button(textos.ACAO_BOTAO_FECHAR, id="fechar")
            yield RichLog(id="saida", markup=False, highlight=False)

    def on_mount(self) -> None:
        self.query_one("#saida", RichLog).border_title = textos.ACAO_TITULO_NOVO
        if self._projeto0 is not None:
            self.query_one("#projeto", Select).value = self._projeto0
        self._projeto_mudou()

    # --- estado --------------------------------------------------------
    def _projeto(self) -> str | None:
        v = self.query_one("#projeto", Select).value
        return v if isinstance(v, str) else None

    def _destino(self) -> str | None:
        v = self.query_one("#destino", Select).value
        return v if isinstance(v, str) else None

    def _receita(self) -> Receita | None:
        nome = self._projeto()
        return next((r for r in self._visao.receitas if r.nome == nome), None)

    def _secao(self) -> SecaoReceita | None:
        r, d = self._receita(), self._destino()
        return r.secoes.get(d) if r is not None and d is not None else None

    def _capacidades(self) -> frozenset[str]:
        ad = self._hub.adaptadores.get(self._destino() or "")
        return frozenset(ad.capacidades) if ad is not None else frozenset()

    def _slurm(self) -> bool:
        s = self._secao()
        return (
            s is not None
            and "submeter" in self._capacidades()
            and (s.job is not None or s.submeter is not None)
        )

    def _projeto_mudou(self) -> None:
        r = self._receita()
        destinos = [d for d in (r.secoes if r else {}) if d in self._hub.adaptadores]
        sel = self.query_one("#destino", Select)
        atual = self._destino()
        sel.set_options([(d, d) for d in destinos])
        if self._destino0 is not None and self._destino0 in destinos:
            sel.value = self._destino0
        elif atual in destinos:
            sel.value = atual
        elif len(destinos) == 1:
            sel.value = destinos[0]
        if r is not None and r.erro:
            self._linha(r.erro)
        self._destino_mudou()

    def _destino_mudou(self) -> None:
        sel = self.query_one("#particao", Select)
        s = self._secao()
        if self._slurm() and s is not None:
            recursos = self._visao.recursos.get(self._destino() or "", [])
            sel.set_options(
                (
                    textos.ACAO_PARTICAO_LIVRES.format(
                        rotulo=r.rotulo, livres=r.livres, total=r.total
                    ),
                    r.rotulo,
                )
                for r in recursos
            )
            if s.particao and any(r.rotulo == s.particao for r in recursos):
                sel.value = s.particao
        self._atualizar_botoes()

    def _atualizar_botoes(self) -> None:
        if not self.is_mounted:
            return
        s = self._secao()
        caps = self._capacidades()
        slurm = self._slurm()
        self.query_one("#particao", Select).display = slurm
        self.query_one("#array", Input).display = slurm and s is not None and s.job is not None
        self.query_one("#enviar-antes", Checkbox).display = "enviar" in caps and s is not None
        r = self._receita()
        pronto = s is not None and r is not None and not r.erro and not self._ocupado
        for bid, cap, _ in _BOTOES:
            b = self.query_one(f"#{bid}", Button)
            b.display = cap in caps
            b.disabled = not pronto

    @on(Select.Changed, "#projeto")
    def _projeto_trocado(self) -> None:
        self._projeto_mudou()

    @on(Select.Changed, "#destino")
    def _destino_trocado(self) -> None:
        self._destino_mudou()

    # --- ações ---------------------------------------------------------
    @on(Button.Pressed, "#fechar")
    def _fechar(self) -> None:
        self.dismiss()

    @on(Button.Pressed, "#enviar")
    def _enviar(self) -> None:
        p, d = self._projeto(), self._destino()
        if p and d:
            self._iniciar(textos.ACAO_BOTAO_ENVIAR, lambda saida: self._hub.enviar(p, d, saida))

    @on(Button.Pressed, "#trazer")
    def _trazer(self) -> None:
        p, d = self._projeto(), self._destino()
        if p and d:
            self._iniciar(textos.ACAO_BOTAO_TRAZER, lambda saida: self._hub.trazer(p, d, saida))

    @on(Button.Pressed, "#ambiente")
    def _ambiente(self) -> None:
        p, d = self._projeto(), self._destino()
        if not (p and d):
            return

        def rodar(saida):
            codigo = self._hub.montar_ambiente(p, d, saida)
            if codigo != 0:
                raise RuntimeError(textos.ACAO_AMBIENTE_FALHOU.format(codigo=codigo))
            return textos.ACAO_CODIGO.format(codigo=codigo)

        self._iniciar(textos.ACAO_BOTAO_AMBIENTE, rodar)

    @on(Button.Pressed, "#submeter")
    def _submeter(self) -> None:
        p, d, s = self._projeto(), self._destino(), self._secao()
        if not (p and d and s):
            return
        particao = array = None
        if self._slurm():
            v = self.query_one("#particao", Select).value
            particao = v if isinstance(v, str) else None
            if s.job is not None:
                array = self.query_one("#array", Input).value.strip() or None
                if array is not None and not _ARRAY.match(array):
                    self._linha(textos.ACAO_ARRAY_INVALIDO)
                    return
        antes = self.query_one("#enviar-antes", Checkbox).value

        def rodar(saida):
            job = self._hub.submeter(p, d, particao, array, antes, saida=saida)
            return textos.ACAO_SUBMETIDO.format(job=job)

        self._iniciar(textos.ACAO_BOTAO_SUBMETER, rodar)
