#!/bin/bash
# Run from an extracted signed Linux release. Never installs as root.
set -euo pipefail
release=$(cd "$(dirname "$0")" && pwd)
[[ "$EUID" -ne 0 ]] || { echo 'Install Freemind as your desktop user, without sudo.' >&2; exit 1; }
[[ -f "$release/release.json" ]] || { echo 'Run install.sh from an extracted Freemind Linux release.' >&2; exit 1; }
install_root="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/freemind}"
python3 "$release/update.py" install-local --directory "$release" --prefix "$install_root"
python3 "$release/integrate.py" "$install_root"
