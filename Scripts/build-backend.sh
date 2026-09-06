#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
# Keep dependencies built for the app's minimum OS separate from older local
# builds, which inherited the build machine's (potentially newer) macOS target.
export MACOSX_DEPLOYMENT_TARGET=14.0
cache="$root/.build-support"
build="$cache/backend-$(uname -m)-macos$MACOSX_DEPLOYMENT_TARGET"
mkdir -p "$build" Resources/bin Resources/licenses
fetch() {
  if [ ! -f "$cache/$1.tar.gz" ]; then curl -fL "$2" -o "$cache/$1.tar.gz"; fi
  actual=$(shasum -a 256 "$cache/$1.tar.gz" | cut -d ' ' -f 1)
  [ "$actual" = "$3" ] || { echo "Checksum mismatch: $1" >&2; exit 1; }
}
fetch libevent https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz 92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb
fetch tmux https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz 16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951
if [ ! -f "$build/prefix/lib/libevent.a" ]; then
  tar -xzf "$cache/libevent.tar.gz" -C "$build"
  cd "$build/libevent-2.1.12-stable"
  CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" ./configure --prefix="$build/prefix" --disable-shared --enable-static --disable-openssl --disable-samples --disable-libevent-regress --disable-dependency-tracking
  make -j4
  make install
fi
if [ ! -f "$build/tmux-3.5a/Makefile" ]; then
  tar -xzf "$cache/tmux.tar.gz" -C "$build"
fi
cd "$build/tmux-3.5a"
if [ ! -f Makefile ]; then
  PKG_CONFIG_PATH="$build/prefix/lib/pkgconfig" CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -I$build/prefix/include" LDFLAGS="-L$build/prefix/lib" ./configure --disable-dependency-tracking --disable-utf8proc
fi
make -j4
cp tmux "$root/Resources/bin/tmux"
cp COPYING "$root/Resources/licenses/tmux.txt"
cp "$build/libevent-2.1.12-stable/LICENSE" "$root/Resources/licenses/libevent.txt"
otool -L "$root/Resources/bin/tmux"
