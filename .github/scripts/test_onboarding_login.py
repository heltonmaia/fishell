#!/usr/bin/env python3
"""Primeira execucao: o fishell pergunta o login do NPAD e grava no config.sh.

Antes havia um passo "rode este sed" no roteiro, que confundia o aluno logo
depois de ele colar a chave no formulario do NPAD. Agora o proprio script
pergunta. O caminho so' existe com tty, entao precisa de pty; e as tres
recusas (sem chave, sem tty, login invalido) tambem sao verificadas, porque
gravar lixo no config.sh e' pior que nao perguntar.
"""
import os
import pty
import select
import subprocess
import sys
import tempfile
import time

ESPERA = 10


def roda(cwd, home, resposta=None):
    """Roda o fishell num pty. `resposta` e' o que digitar no prompt."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ.update(NO_COLOR="1", HOME=home, TERM="xterm", FISHELL_LANG="pt")
        os.execvp("bash", ["bash", "bin/fishell.sh"])
    buf, fim, enviado = b"", time.time() + ESPERA, resposta is None
    while time.time() < fim:
        if select.select([fd], [], [], 0.3)[0]:
            try:
                pedaco = os.read(fd, 65536)
            except OSError:
                break
            if not pedaco:
                break
            buf += pedaco
        elif not enviado and b"login do NPAD" in buf:
            time.sleep(0.3)
            os.write(fd, resposta.encode() + b"\n")
            enviado = True
        elif os.waitpid(pid, os.WNOHANG)[0]:
            break
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return buf.decode(errors="replace"), enviado


def prepara(raiz, nome, com_chave=True):
    repo = os.path.join(raiz, nome)
    arquivos = subprocess.run(["git", "ls-files"], stdout=subprocess.PIPE,
                              check=True, text=True).stdout.split()
    os.makedirs(repo)
    tar = os.path.join(raiz, f"{nome}.tar")
    with open(tar, "wb") as saida:
        subprocess.run(["tar", "-cf", "-"] + arquivos, stdout=saida, check=True)
    subprocess.run(["tar", "-xf", tar, "-C", repo], check=True)
    ssh = os.path.join(repo, ".ssh")
    os.makedirs(ssh, exist_ok=True)
    if com_chave:
        subprocess.run(["ssh-keygen", "-t", "rsa", "-b", "2048", "-N", "",
                        "-C", "ci@exemplo", "-f", os.path.join(ssh, "id_rsa")],
                       stdout=subprocess.DEVNULL, check=True)
    home = os.path.join(raiz, f"home-{nome}")
    os.makedirs(os.path.join(home, ".ssh"))
    return repo, home


def npad_user(repo):
    with open(os.path.join(repo, "config.sh"), encoding="utf-8") as f:
        for linha in f:
            if linha.strip().startswith("NPAD_USER="):
                return linha.split("=", 1)[1].strip().strip("\"'")
    return None


problemas = []
with tempfile.TemporaryDirectory() as tmp:
    # 1. com chave e com tty: pergunta, grava e segue para o setup.
    repo, home = prepara(tmp, "ok")
    tela, perguntou = roda(repo, home, "ci_user")
    if not perguntou:
        problemas.append("nao perguntou o login tendo chave e tty")
    if npad_user(repo) != "ci_user":
        problemas.append(f"nao gravou o login: NPAD_USER={npad_user(repo)!r}")
    if "sed -i" in tela:
        problemas.append("o roteiro ainda manda rodar um sed")
    if "alias 'npad'" not in tela:
        problemas.append("nao seguiu para o setup depois de responder")

    # 2. login invalido nao entra no config.
    repo, home = prepara(tmp, "ruim")
    tela, _ = roda(repo, home, "nome com espaco")
    if npad_user(repo) != "seu_usuario_aqui":
        problemas.append(f"gravou login invalido: {npad_user(repo)!r}")
    if "inválido" not in tela:
        problemas.append("nao avisou que o login era invalido")

    # 3. sem chave nao ha' cadastro, logo nao ha' login a perguntar.
    repo, home = prepara(tmp, "semchave", com_chave=False)
    tela, _ = roda(repo, home, None)
    if "login do NPAD" in tela:
        problemas.append("perguntou o login sem haver chave")

    # 4. sem tty (CI, pipe) tem que cair no roteiro, nunca travar num prompt.
    repo, home = prepara(tmp, "pipe")
    saida = subprocess.run(["bash", "bin/fishell.sh"], cwd=repo, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           timeout=30, env=dict(os.environ, NO_COLOR="1", HOME=home,
                                                FISHELL_LANG="pt")).stdout
    if "login do NPAD" in saida:
        problemas.append("tentou perguntar o login sem tty")
    if "rode de novo" not in saida:
        problemas.append("sem tty, nao mostrou o passo 'rode de novo'")

if problemas:
    print("roteiro de primeira execucao:")
    for p in problemas:
        print("  " + p)
    sys.exit(1)
print("primeira execucao: pergunta o login, grava, e recusa o que deve recusar")
