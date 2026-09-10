#!/usr/bin/env python3
"""Acusa texto de UI escrito direto no código, sem passar pela tabela de idioma.

Foi assim que o `action_download` ficou em inglês mesmo com a interface em
português: uma substituição da passagem de i18n pegou só a primeira ocorrência
e ninguém notou, porque upload e download são interativos e o CI não os roda.

A regra: todo argumento de log_*/Log-* tem que citar uma chave de idioma.
"""
import io
import re
import sys

CASOS = [
    ("src/bash/fishell.sh", "utf-8",
     re.compile(r'^\s*log_(?:info|ok|warn|err|step|work)\s+"([^"]*)"', re.M),
     re.compile(r'\$\{?L_[A-Z0-9_]+')),
    ("src/powershell/fishell.ps1", "utf-8-sig",
     re.compile(r'^\s*Log-(?:Info|Ok|Warn|Err|Step|Work)\s+"([^"]*)"', re.M),
     re.compile(r'\$L\.[A-Z0-9_]+|\$\(\$L\.')),
]

falhas = []
for path, enc, chamada, referencia in CASOS:
    texto = io.open(path, encoding=enc).read()
    for m in chamada.finditer(texto):
        arg = m.group(1)
        if not referencia.search(arg):
            linha = texto[:m.start()].count("\n") + 1
            falhas.append(f"{path}:{linha}: {arg!r}")

if falhas:
    print("texto de UI fora da tabela de idioma:")
    for f in falhas:
        print("  " + f)
    sys.exit(1)
print("nenhum texto de UI escrito direto no código")
