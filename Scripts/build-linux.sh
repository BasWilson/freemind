#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/linux-env.sh
configuration="${1:-debug}"
[[ "$configuration" == debug || "$configuration" == release ]] || { echo 'Usage: bash Scripts/build-linux.sh [debug|release] [--core-only]' >&2; exit 1; }
command -v swift >/dev/null || { echo 'Install Swift 6.1 or newer; see plans/linux-omarchy-port.md.' >&2; exit 1; }
flags=(--disable-sandbox --cache-path "$PWD/.build/cache" -c "$configuration" -j "${FREEMIND_BUILD_JOBS:-6}")
swift build "${flags[@]}" --product freemind-helper
if [[ "${2:-}" == --core-only ]]; then exit 0; fi
pkg-config --exists 'gtk4 >= 4.14' vte-2.91-gtk4 gtksourceview-5 || { echo 'Install GTK4, VTE and GtkSourceView: omarchy pkg add gtk4 vte4 gtksourceview5' >&2; exit 1; }
swift build --package-path Linux --scratch-path "$PWD/.build/linux" "${flags[@]}"
core_bin=$(swift build "${flags[@]}" --show-bin-path)
ui_bin=$(swift build --package-path Linux --scratch-path "$PWD/.build/linux" "${flags[@]}" --show-bin-path)
cp "$core_bin/freemind-helper" "$ui_bin/freemind-helper"
cp Linux/Support/update.py "$ui_bin/update.py"
echo "Run: bash Scripts/run-linux.sh /path/to/workspace"
