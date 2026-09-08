#!/usr/bin/env python3
"""Confere a invariante do painel: 50 colunas entre as barras.

A caixa do CONTROL PANEL é montada com padding contado à mão nos dois ports
(printf '%-20s'/'%-16s' no bash, .PadRight() no ps1). Um título ou hint mais
longo que o pad desalinha a caixa inteira sem quebrar nada mais — daí o check.

Uso: FISHELL_NOANIM=1 NO_COLOR=1 ./fishell.sh </dev/null | check_panel.py
"""
import sys

WIDTH = 50
BORDERS = ("╔", "╠", "╚", "║")

lines = [l.rstrip("\n") for l in sys.stdin]
panel = [l for l in lines if l[:1] in BORDERS]

if not panel:
    sys.exit("nenhuma linha de painel na entrada — o menu chegou a desenhar?")

bad = [l for l in panel if len(l) - 2 != WIDTH]
if bad:
    print(f"linhas fora das {WIDTH} colunas:")
    for l in bad:
        print(f"  {len(l) - 2:>3}  {l!r}")
    sys.exit(1)

print(f"painel ok — {len(panel)} linhas, {WIDTH} colunas")
