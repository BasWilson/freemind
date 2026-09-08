#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/linux-env.sh
configuration="${FREEMIND_PACKAGE_CONFIGURATION:-release}"
bash Scripts/build-linux.sh "$configuration"
ui_bin=$(swift build --package-path Linux --scratch-path "$PWD/.build/linux" -c "$configuration" --show-bin-path)
python3 Scripts/package-linux.py "$ui_bin"
