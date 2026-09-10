#!/usr/bin/env bash
# Testa validate_pubkey do src/bash/fishell.sh.
#
# Essa funcao e' a ultima barreira antes de o aluno colar a chave no formulario
# de cadastro do NPAD. Uma chave truncada aceita ali custa dias: o cadastro vai,
# o e-mail chega, e so' na hora de conectar e' que falha.
#
# A funcao e' extraida do fonte (nao reescrita aqui) pra o teste valer sobre o
# codigo de verdade — sourcear o script inteiro dispararia o main().
set -euo pipefail

eval "$(sed -n '/^validate_pubkey()/,/^}/p' src/bash/fishell.sh)"

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
ssh-keygen -t rsa -b 2048 -N '' -C 'fishell@ci' -f "$t/ok" >/dev/null

: > "$t/vazio.pub"
head -c 60 "$t/ok.pub"                    > "$t/truncada.pub"
cat "$t/ok.pub" "$t/ok.pub"               > "$t/duas.pub"
sed 's/^ssh-rsa/ssh-ed25519/' "$t/ok.pub" > "$t/tipo.pub"
printf 'ssh-rsa AAAA nao-e-base64\n'      > "$t/lixo.pub"

fail=0
check() {  # <arquivo> <esperado: aceita|rejeita>
    local f="$1" want="$2" got
    if validate_pubkey "$t/$f.pub"; then got=aceita; else got=rejeita; fi
    if [[ "$got" == "$want" ]]; then
        printf '  ok       %-10s %s\n' "$f" "$got"
    else
        printf '  FALHOU   %-10s esperado=%s obtido=%s\n' "$f" "$want" "$got"
        fail=1
    fi
}

check ok       aceita
check vazio    rejeita
check truncada rejeita
check duas     rejeita
check tipo     rejeita     # NPAD exige rsa
check lixo     rejeita

exit "$fail"
