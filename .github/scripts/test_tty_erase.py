#!/usr/bin/env python3
"""Confere que o fishell preserva o `erase` do terminal.

`read -rsn1` deixa o tty em modo nao-canonico e isso precisa ser desfeito. A
forma obvia, `stty sane`, descarta a configuracao do terminal e impoe
erase=^?. Em terminais que mandam ^H no backspace (o do Colab e' um) o usuario
digita e nao consegue mais apagar. A correcao e' guardar o estado com
`stty -g` na entrada e restaura-lo.

O teste precisa de um pty E de tempo: a disciplina de linha interpreta o erase
no momento em que o byte CHEGA, entao mandar tudo de uma vez testaria as
configuracoes iniciais, nao as que o script aplica. Por isso cada tecla so' e'
enviada depois que o prompt correspondente aparece.

A funcao e' extraida do fonte, nao reescrita aqui.
"""
import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time

FONTE = "src/bash/fishell.sh"

texto = open(FONTE, encoding="utf-8").read()
trecho = re.search(r"TTY_STATE=\"\".*?\n\}\n", texto, re.S)
if not trecho:
    sys.exit("nao achei TTY_STATE/tty_restore no fonte")


def roda(script_path, passos):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", script_path])
    saida = b""
    for prompt, tecla in passos:
        prazo = time.time() + 5
        while prompt.encode() not in saida and time.time() < prazo:
            if select.select([fd], [], [], 0.2)[0]:
                try:
                    saida += os.read(fd, 4096)
                except OSError:
                    break
        time.sleep(0.15)
        os.write(fd, tecla)
    prazo = time.time() + 3
    while time.time() < prazo:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                bloco = os.read(fd, 4096)
                if not bloco:
                    break
                saida += bloco
            except OSError:
                break
    os.close(fd)
    os.waitpid(pid, 0)
    return saida.decode(errors="replace")


with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
    f.write("#!/usr/bin/env bash\n")
    f.write("stty erase '^H' 2>/dev/null\n")   # terminal que manda ^H, tipo o do Colab
    f.write(trecho.group(0))
    f.write("\nprintf 'PROMPT: '\ntty_restore\nread -r v\nprintf 'VALOR=[%s]\\n' \"$v\"\n")
    caminho = f.name

try:
    saida = roda(caminho, [("PROMPT:", b"xy\x08z\n")])
finally:
    os.unlink(caminho)

achado = re.search(r"VALOR=\[([^\]]*)\]", saida)
obtido = achado.group(1) if achado else "<nada>"
if obtido != "xz":
    print(f"o backspace ^H nao apagou: esperado 'xz', obtido '{obtido}'")
    print(saida)
    sys.exit(1)
print("tty_restore preserva o erase do terminal")
