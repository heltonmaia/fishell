#!/usr/bin/env bash
# Entrypoint do fishell. O codigo vive em src/bash/fishell.sh; este wrapper
# so existe pra `./bin/fishell.sh` funcionar de qualquer diretorio.
set -o pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../src/bash" && pwd)/fishell.sh" "$@"
