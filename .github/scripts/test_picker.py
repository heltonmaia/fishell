#!/usr/bin/env python3
"""Navega no seletor de arquivos local: setas, enter para entrar, q para sair.

Precisa de pty: o seletor so' liga quando stdin e stdout sao tty, e cada tecla
so' pode ser enviada depois que a tela correspondente aparece.
"""
import os
import pty
import select
import subprocess
import sys
import tempfile
import time


def roda(cwd, teclas):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ["NO_COLOR"] = "1"
        os.execvp("bash", ["bash", "bin/fishell.sh", "upload"])
    visto, buf = [], b""
    for esperar, tecla in teclas:
        prazo = time.time() + 8
        while esperar.encode() not in buf and time.time() < prazo:
            if select.select([fd], [], [], 0.2)[0]:
                try:
                    buf += os.read(fd, 8192)
                except OSError:
                    break
        if esperar.encode() not in buf:
            os.close(fd)
            sys.exit(f"nao apareceu na tela: {esperar!r}")
        visto.append(buf.decode(errors="replace"))
        buf = b""
        time.sleep(0.2)
        os.write(fd, tecla)
    prazo = time.time() + 3
    while time.time() < prazo:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                b = os.read(fd, 8192)
                if not b:
                    break
                buf += b
            except OSError:
                break
    os.close(fd)
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    visto.append(buf.decode(errors="replace"))
    return visto


with tempfile.TemporaryDirectory() as tmp:
    repo = os.path.join(tmp, "repo")
    subprocess.run(["git", "ls-files"], stdout=subprocess.PIPE, check=True)
    arquivos = subprocess.run(["git", "ls-files"], stdout=subprocess.PIPE,
                              check=True, text=True).stdout.split()
    os.makedirs(repo)
    subprocess.run(["tar", "-cf", "-"] + arquivos, stdout=open(f"{tmp}/a.tar", "wb"), check=True)
    subprocess.run(["tar", "-xf", f"{tmp}/a.tar", "-C", repo], check=True)
    cfg = os.path.join(repo, "config.sh")
    modelo = open(os.path.join(repo, "config/config.sh.example"), encoding="utf-8").read()
    modelo = modelo.replace("seu_usuario_aqui", "ci").replace('SSH_ALIAS="npad"', 'SSH_ALIAS="teste.invalid"')
    open(cfg, "w", encoding="utf-8").write(modelo)
    os.environ["HOME"] = os.path.join(tmp, "home")
    os.makedirs(os.environ["HOME"])

    telas = roda(repo, [
        ("escolha o que enviar", b"\033[B"),   # desce
        ("pasta:", b"\033[B"),                 # desce
        ("pasta:", b"\r"),                     # entra na pasta
        ("pasta:", b"q"),                      # cancela
    ])

tudo = "\n".join(telas)
problemas = []
if "subir um" not in tudo:
    problemas.append("a entrada '..' nao aparece em tela nenhuma")
if "config.sh.example" not in tudo:
    problemas.append("o enter nao entrou na subpasta (esperava ver o conteudo dela)")
if "setas movem" not in tudo:
    problemas.append("a linha de ajuda nao aparece")
if problemas:
    print("\n".join(problemas))
    print("--- ultima tela ---")
    print(telas[-2][-800:])
    sys.exit(1)
print("seletor de arquivos: navega, entra em pasta e cancela")
