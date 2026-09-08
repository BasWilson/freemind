#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/linux-env.sh
python3 Tests/LinuxUITests/smoke.py ".build/linux/${FREEMIND_CONFIGURATION:-debug}/freemind-linux"
