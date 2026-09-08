#!/usr/bin/env python3
"""Regenera o screenshot.png do README a partir da UI real do fishell.

Roda o fishell.sh numa cópia temporária do repo (com um NPAD_USER neutro, pra
não publicar o usuário real), captura a saída ANSI através de um pty e desenha
o frame do painel com Pillow.

    python3 tools/make-screenshot.py [-o screenshot.png]

Requer: Pillow e DejaVu Sans Mono (fonts-dejavu-core).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
FONT_REG = f"{FONT_DIR}/DejaVuSansMono.ttf"
FONT_BLD = f"{FONT_DIR}/DejaVuSansMono-Bold.ttf"

SIZE, PAD = 18, 28
FG, BG = (0, 255, 0), (11, 14, 11)
CUBE = [0, 95, 135, 175, 215, 255]


def xterm(n):
    """RGB de uma cor xterm-256."""
    if n < 16:
        return (0, 0, 0)
    if n < 232:
        n -= 16
        return (CUBE[n // 36], CUBE[(n % 36) // 6], CUBE[n % 6])
    return (8 + (n - 232) * 10,) * 3


def capture():
    """Roda o fishell numa cópia descartável e devolve a saída ANSI crua."""
    with tempfile.TemporaryDirectory() as tmp:
        work = os.path.join(tmp, "fishell")
        shutil.copytree(REPO, work, ignore=shutil.ignore_patterns(".git", ".ssh"))
        cfg = os.path.join(work, "config.sh")
        with open(os.path.join(work, "config", "config.sh.example"), encoding="utf-8") as f:
            conf = f.read().replace('NPAD_USER="seu_usuario_aqui"', 'NPAD_USER="usuario"')
        with open(cfg, "w", encoding="utf-8") as f:
            f.write(conf)
        # script(1) dá um pty ao filho — sem isso o fishell desliga as cores.
        # FISHELL_NOANIM=1 é obrigatório: com animação o menu nunca vê o EOF.
        out = subprocess.run(
            ["script", "-qec", "FISHELL_NOANIM=1 ./bin/fishell.sh", "/dev/null"],
            cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=60,
        ).stdout.decode("utf-8", "replace")
    # O painel ainda mostra "off" porque a captura desligou a animação; o que o
    # usuário vê num run normal é "on".
    return out.replace("off\x1b[0m", "on \x1b[0m")


def parse(raw):
    """Extrai o frame do menu e devolve linhas de runs (cor, negrito, texto)."""
    frames = re.split(r"\x1b\[H\x1b\[2J\x1b\[3J", raw)
    # 'CONTROL PANEL' só existe no frame do menu ('╔' também está na arte do logo).
    frame = next((f for f in reversed(frames) if "CONTROL PANEL" in f), None)
    if frame is None:
        sys.exit("painel não encontrado na captura — o fishell chegou a rodar?")

    tok = re.compile(r"\x1b\[([0-9;]*)m")
    lines, color, bold = [], FG, False
    for raw_line in frame.replace("\r", "").split("\n"):
        pos, cur = 0, []
        for m in tok.finditer(raw_line):
            if m.start() > pos:
                cur.append((color, bold, raw_line[pos:m.start()]))
            codes = [c for c in (m.group(1) or "0").split(";") if c]
            i = 0
            while i < len(codes):
                c = int(codes[i])
                if c == 0:
                    color, bold = FG, False
                elif c == 1:
                    bold = True
                elif c == 38 and codes[i + 1:i + 2] == ["5"]:
                    color = xterm(int(codes[i + 2]))
                    i += 2
                i += 1
            pos = m.end()
        if pos < len(raw_line):
            cur.append((color, bold, raw_line[pos:]))
        lines.append(cur)

    text = lambda ln: "".join(t for _, _, t in ln)
    while lines and not text(lines[0]).strip():
        lines.pop(0)
    while lines and not text(lines[-1]).strip():
        lines.pop()
    return lines


def render(lines, out):
    for path in (FONT_REG, FONT_BLD):
        if not os.path.exists(path):
            sys.exit(f"fonte ausente: {path} (apt install fonts-dejavu-core)")
    reg = ImageFont.truetype(FONT_REG, SIZE)
    bld = ImageFont.truetype(FONT_BLD, SIZE)
    # A altura da linha tem que ser exatamente a caixa do bloco cheio, senão as
    # bordas ║ do painel saem com falhas entre uma linha e outra.
    top, bottom = reg.getbbox("█")[1], reg.getbbox("█")[3]
    cw, lh = reg.getlength("M"), bottom - top

    cols = max(len("".join(t for _, _, t in ln)) for ln in lines)
    img = Image.new("RGB", (int(PAD * 2 + cols * cw), int(PAD * 2 + len(lines) * lh)), BG)
    draw = ImageDraw.Draw(img)
    for row, ln in enumerate(lines):
        x, y = PAD, PAD + row * lh - top
        for color, is_bold, text in ln:
            draw.text((x, y), text, font=(bld if is_bold else reg), fill=color)
            x += len(text) * cw
    img.save(out)
    print(f"{out}: {img.width}x{img.height} px, {len(lines)} linhas, {cols} colunas")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default=os.path.join(REPO, "docs", "screenshot.png"))
    args = ap.parse_args()
    render(parse(capture()), args.out)
