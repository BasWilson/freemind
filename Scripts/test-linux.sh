#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/linux-env.sh
swift test --disable-sandbox --cache-path .build/cache -j "${FREEMIND_BUILD_JOBS:-6}" "$@"
