#!/usr/bin/env bash
# Entrypoint do fishell. O codigo vive em src/bash/fishell.sh; este wrapper
# so existe pra `./bin/fishell.sh` funcionar de qualquer diretorio.
#
# Chama o interpretador explicitamente em vez de exec no script: em mount FUSE
# (o Google Drive montado no Colab, por exemplo) o bit de execucao do git nao
# sobrevive, e um exec direto morreria com "Permission denied" mesmo o usuario
# tendo invocado como `bash bin/fishell.sh`.
set -o pipefail
exec "${BASH:-/usr/bin/env bash}" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../src/bash" && pwd)/fishell.sh" "$@"
