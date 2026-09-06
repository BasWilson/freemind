#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

bash Scripts/build-app.sh release
app="$root/dist/Freemind.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
architecture=$(lipo -archs "$app/Contents/MacOS/Freemind")
case "$architecture" in
  arm64) supported_macs="Apple Silicon Macs (M1 or newer)" ;;
  x86_64) supported_macs="Intel Macs" ;;
  *) echo "Unexpected app architecture: $architecture" >&2; exit 1 ;;
esac

for executable in "$app/Contents/MacOS/Freemind" "$app/Contents/MacOS/freemind-helper" "$app/Contents/Resources/bin/tmux"; do
  [ -x "$executable" ]
  [ "$(lipo -archs "$executable")" = "$architecture" ]
  # Check the actual executable target, not just the app's Info.plist.
  actual_minimum=$(xcrun vtool -show-build "$executable" | awk '$1 == "minos" { print $2 }')
  [ "$actual_minimum" = "$minimum_os" ] || { echo "Wrong minimum macOS version in $executable: $actual_minimum" >&2; exit 1; }
  codesign --verify --strict "$executable"
done
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Frameworks/Sparkle.framework/Sparkle"
otool -L "$app/Contents/MacOS/Freemind" | /usr/bin/grep -q '@rpath/Sparkle.framework/'
plutil -lint "$app/Contents/Info.plist"

staging=$(mktemp -d "$root/dist/.package-app.XXXXXX")
trap 'rm -rf "$staging"' EXIT
package="$staging/Freemind"
mkdir -p "$package"
ditto --norsrc --noextattr --noqtn "$app" "$package/Freemind.app"
ln -s /Applications "$package/Applications"
cat > "$package/READ ME.txt" <<EOF
Freemind $version

Requires macOS $minimum_os or newer on $supported_macs.

INSTALL
1. Unzip the download.
2. Drag Freemind.app onto the Applications shortcut in this folder.
3. Open Freemind from Applications.

FIRST OPEN
This build is locally signed and has not been notarized by Apple.
If macOS blocks Freemind because the developer cannot be verified, dismiss
the alert, open System Settings > Privacy & Security, then select Open Anyway
for Freemind and confirm Open. This is normally needed only once.
Apple's instructions: https://support.apple.com/en-us/102445

GET STARTED
Use Command-O to open a project folder.
Use Shift-Command-T for a shell terminal, or Command-T for Codex.
Codex terminals require a separate Codex CLI installation and your own login.
Freemind reuses the Codex CLI available in your login shell; if it isn't found,
select its executable in the workspace's Terminal Defaults.
Git features require Git to be installed on your Mac.
Freemind's terminal backend and rendering resources are included in the app.

Quitting Freemind keeps terminal sessions running. Use Quit and Stop Terminals
from the Freemind menu when you want to stop them too.
EOF

name="Freemind-$version-macOS-$architecture.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$package" "$staging/$name"
unzip -tq "$staging/$name"
mv -f "$staging/$name" "$root/dist/$name"
cd "$root/dist"
shasum -a 256 "$name" > "$name.sha256"
# Sparkle gets an app-only archive, separate from the first-install folder.
# ditto preserves the symlinks required by the embedded Sparkle framework.
update_name="Freemind-$version-macOS-$architecture-update.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$update_name"
unzip -tq "$staging/$update_name"
mv -f "$staging/$update_name" "$root/dist/$update_name"
shasum -a 256 "$update_name" > "$update_name.sha256"
echo "$root/dist/$name"
