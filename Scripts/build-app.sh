#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/module-cache"
python3 Scripts/configure-release.py --check
bash Scripts/build-backend.sh
swift build --disable-sandbox --cache-path .build/cache -c "$configuration"
mkdir -p .build-support/compiled-icon
xcrun actool "$root/Resources/Freemind.icon" "$root/Resources/Assets.xcassets" --compile "$root/.build-support/compiled-icon" \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 --app-icon Freemind \
    --accent-color AccentColor --output-format human-readable-text --output-partial-info-plist "$root/.build-support/icon-info.plist"
bin=$(swift build --disable-sandbox --cache-path .build/cache -c "$configuration" --show-bin-path)
destination="$root/dist/Freemind.app"
# A changing build version lets Launch Services and the Dock invalidate cached
# artwork when the local app is rebuilt in place.
previous_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$destination/Contents/Info.plist" 2>/dev/null || echo 0)
case "$previous_build" in ''|*[!0-9]*) previous_build=0 ;; esac
# Assemble a fresh bundle so previous builds cannot leak extra files into a zip.
mkdir -p "$root/dist"
staging=$(mktemp -d "$root/dist/.build-app.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Freemind.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Freemind" "$app/Contents/MacOS/Freemind"
cp "$bin/freemind-helper" "$app/Contents/MacOS/freemind-helper"
cp -R Resources/bin Resources/licenses "$app/Contents/Resources/"
# SwiftTerm probes this upstream resource name when loading its Metal shaders.
cp -R "$bin/Freemind_SwiftTerm.bundle" "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp .build-support/compiled-icon/Assets.car .build-support/compiled-icon/Freemind.icns "$app/Contents/Resources/"
cp Vendor/SwiftTerm/LICENSE "$app/Contents/Resources/licenses/SwiftTerm.txt"
# Preserve Sparkle's framework symlinks and signed installer/XPC bundles.
sparkle="$root/.build/artifacts/sparkle/Sparkle"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/licenses/Sparkle.txt"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((previous_build + 1))" "$app/Contents/Info.plist"
python3 Scripts/configure-release.py "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Resources/bin/tmux"
codesign --force --sign - "$app/Contents/MacOS/freemind-helper"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
rm -rf "$destination"
mv "$app" "$destination"
echo "$destination"
