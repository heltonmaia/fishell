#!/usr/bin/env bash
# Testa a leitura de teclas do menu: setas, enter e caractere comum.
#
# A funcao so' entra no caminho interessante quando stdin E stdout sao tty,
# entao o teste roda dentro de script(1), que da' um pty. Sem isso ela cai no
# ramo de linha e nada disso e' exercitado.
#
# A funcao e' extraida do fonte, nao reescrita aqui, pra o teste valer sobre o
# codigo de verdade.
set -uo pipefail

fonte="$PWD/src/bash/fishell.sh"
falhou=0

testa() {  # <nome> <bytes enviados> <esperado>
    local nome="$1" envio="$2" quero="$3" got
    got=$(printf '%s' "$envio" | script -qec "bash -c '
        eval \"\$(sed -n \"/^menu_prompt_read()/,/^}/p\" $fonte)\"
        menu_prompt_read k; printf \"R=%s\n\" \"\$k\"'" /dev/null 2>/dev/null \
        | grep -o 'R=.*' | head -1 | cut -d= -f2- | tr -d '\r')
    if [[ "$got" == "$quero" ]]; then
        printf '  ok       %-10s -> %s\n' "$nome" "$got"
    else
        printf '  FALHOU   %-10s esperado=%s obtido=%s\n' "$nome" "$quero" "${got:-<vazio>}"
        falhou=1
    fi
}

testa "seta cima"  $'\033[A' up
testa "seta baixo" $'\033[B' down
testa "enter"      $'\n'     enter
testa "tecla"      '3'       3

exit "$falhou"
