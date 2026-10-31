"""Leitura do fishell.toml na raiz de um projeto."""

from __future__ import annotations

import tomllib
from pathlib import Path

from .modelos import ErroReceita, Receita, SecaoReceita, Transferencia

ARQUIVO = "fishell.toml"
_TEXTOS = ("remoto", "ambiente", "job", "submeter", "comando", "particao", "log")
_LISTAS = ("enviar", "trazer")
_CHAVES = frozenset(_TEXTOS + _LISTAS)
_CHAVES_ITEM = frozenset({"de", "para", "incluir", "excluir"})


def _lista_de_textos(valor: object, onde: str) -> tuple[str, ...]:
    if not isinstance(valor, list) or not all(isinstance(v, str) for v in valor):
        raise ErroReceita(f"{onde}: esperava uma lista de textos")
    return tuple(valor)


def parse_transferencia(item: str | dict) -> Transferencia:
    """Lê 'a/ -> b/', 'a/' (mesmo caminho nos dois lados) ou uma tabela."""
    if isinstance(item, str):
        if " -> " in item:
            de, para = (p.strip() for p in item.split(" -> ", 1))
        else:
            de = para = item.strip()
        if not de or not para:
            raise ErroReceita(f"transferência inválida: {item!r}")
        return Transferencia(de, para)
    if isinstance(item, dict):
        desconhecidas = set(item) - _CHAVES_ITEM
        if desconhecidas:
            raise ErroReceita(f"chave desconhecida na transferência: {sorted(desconhecidas)[0]}")
        de, para = item.get("de"), item.get("para", item.get("de"))
        if not isinstance(de, str) or not isinstance(para, str) or not de or not para:
            raise ErroReceita(f"transferência sem 'de': {item!r}")
        return Transferencia(
            de,
            para,
            _lista_de_textos(item.get("incluir", []), "incluir"),
            _lista_de_textos(item.get("excluir", []), "excluir"),
        )
    raise ErroReceita(f"transferência inválida: {item!r}")


def _transferencias(valor: object, chave: str) -> tuple[Transferencia, ...]:
    if not isinstance(valor, list):
        raise ErroReceita(f"{chave}: esperava uma lista")
    return tuple(parse_transferencia(i) for i in valor)


def _secao(destino: str, dados: dict) -> SecaoReceita:
    for chave in dados:
        if chave not in _CHAVES:
            raise ErroReceita(f"[{destino}] chave desconhecida: {chave}")
    for chave in _TEXTOS:
        if chave in dados and not isinstance(dados[chave], str):
            raise ErroReceita(f"[{destino}] {chave}: esperava texto")
    if "job" in dados and "submeter" in dados:
        raise ErroReceita(f"[{destino}] job e submeter são exclusivos")
    if "submeter" in dados and "log" not in dados:
        raise ErroReceita(f"[{destino}] submeter exige log")
    return SecaoReceita(
        destino=destino,
        remoto=dados.get("remoto"),
        enviar=_transferencias(dados.get("enviar", []), f"[{destino}] enviar"),
        trazer=_transferencias(dados.get("trazer", []), f"[{destino}] trazer"),
        ambiente=dados.get("ambiente"),
        job=dados.get("job"),
        submeter=dados.get("submeter"),
        comando=dados.get("comando"),
        particao=dados.get("particao"),
        log=dados.get("log"),
    )


def ler_receita(raiz: Path) -> Receita | None:
    """None sem fishell.toml; com erro, devolve Receita vazia com `erro`."""
    arquivo = Path(raiz) / ARQUIVO
    if not arquivo.is_file():
        return None
    nome = Path(raiz).resolve().name
    try:
        try:
            dados = tomllib.loads(arquivo.read_text(encoding="utf-8"))
        except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
            raise ErroReceita(f"TOML inválido: {e}") from e
        if "nome" in dados:
            if not isinstance(dados["nome"], str):
                raise ErroReceita("nome: esperava texto")
            nome = dados.pop("nome")
        secoes = {}
        for destino, conteudo in dados.items():
            if not isinstance(conteudo, dict):
                raise ErroReceita(f"chave desconhecida no topo: {destino}")
            secoes[destino] = _secao(destino, conteudo)
    except ErroReceita as e:
        return Receita(Path(raiz), nome, {}, erro=str(e))
    return Receita(Path(raiz), nome, secoes)
