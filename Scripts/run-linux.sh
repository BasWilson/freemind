#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# Resolve a relative workspace argument before changing to the repository.
args=("$@")
if [[ $# -eq 1 && "$1" != --help ]]; then args=("$(realpath -m -- "$1")"); fi
cd "$root"
source Scripts/linux-env.sh
exec ".build/linux/${FREEMIND_CONFIGURATION:-debug}/freemind-linux" "${args[@]}"
