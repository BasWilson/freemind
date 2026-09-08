#!/bin/bash
# Source this file from the repository root. Normal system installations use
# PATH/pkg-config as-is; the optional local bootstrap stays in .build-support.
if ! command -v swift >/dev/null && [[ -x "$PWD/.build-support/swiftly/toolchains/6.3.3/usr/bin/swift" ]]; then
  export PATH="$PWD/.build-support/swiftly/toolchains/6.3.3/usr/bin:$PATH"
fi
freemind_deps="$PWD/.build-support/linux-deps/root/usr"
if [[ -d "$freemind_deps/lib" ]]; then
  export LD_LIBRARY_PATH="$freemind_deps/lib:$freemind_deps/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export XDG_DATA_DIRS="$freemind_deps/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  export PKG_CONFIG_PATH="$freemind_deps/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
unset freemind_deps
