#!/usr/bin/env python3
"""Confere que as tabelas de idioma dos dois ports estão em paridade.

Uma chave que existe no bash mas não no ps1 (ou vice-versa) não quebra nada em
tempo de parse: `$L.FOO` inexistente vira `$null` e a UI simplesmente imprime
vazio. Este check pega isso antes de virar bug silencioso no Windows.

Também acusa chave usada sem estar definida, nos dois ports.

Uso: python3 .github/scripts/check_i18n.py
"""
import io
import re
import sys

BASH = "src/bash/fishell.sh"
PS1 = "src/powershell/fishell.ps1"

sh = io.open(BASH, encoding="utf-8").read()
ps = io.open(PS1, encoding="utf-8-sig").read()

sh_block = re.search(r"set_lang\(\) \{.*?\n\}\n", sh, re.S)
ps_block = re.search(r"function Set-Lang \{.*?\n\}\nSet-Lang", ps, re.S)
if not sh_block or not ps_block:
    sys.exit("não achei set_lang / Set-Lang — a estrutura mudou?")

sh_keys = set(re.findall(r"\bL_([A-Z0-9_]+)=", sh_block.group(0)))
ps_keys = set(re.findall(r"(?:^|[{;\s])([A-Z][A-Z0-9_]*)=", ps_block.group(0), re.M))
sh_used = set(re.findall(r"\$\{?L_([A-Z0-9_]+)", sh))
ps_used = set(re.findall(r"\$L\.([A-Z0-9_]+)", ps))

problems = []
if sh_keys - ps_keys:
    problems.append(f"definidas só no bash: {sorted(sh_keys - ps_keys)}")
if ps_keys - sh_keys:
    problems.append(f"definidas só no ps1: {sorted(ps_keys - sh_keys)}")
if sh_used - sh_keys:
    problems.append(f"usadas sem definir no bash: {sorted(sh_used - sh_keys)}")
if ps_used - ps_keys:
    problems.append(f"usadas sem definir no ps1: {sorted(ps_used - ps_keys)}")

if problems:
    print("tabelas de idioma fora de paridade:")
    for p in problems:
        print("  " + p)
    sys.exit(1)

print(f"i18n ok — {len(sh_keys)} chaves idênticas nos dois ports")
