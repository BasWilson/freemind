#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
output="${1:-$root/dist}"
: "${FREEMIND_RELEASE_VERSION:?Set the release version}"
: "${FREEMIND_UPDATE_REPOSITORY:?Set the GitHub owner/repo}"
: "${SPARKLE_PUBLIC_ED_KEY:?Set the public update signing key}"
: "${SPARKLE_PRIVATE_ED_KEY:?Set the private update signing key}"
python3 Scripts/configure-release.py --check

architecture=$(uname -m)
archive="Freemind-$FREEMIND_RELEASE_VERSION-macOS-$architecture-update.zip"
test -f "$output/$archive"
staging=$(mktemp -d "$output/.appcast.XXXXXX")
trap 'rm -rf "$staging"' EXIT
cp "$output/$archive" "$staging/"
sparkle="$root/.build/artifacts/sparkle/Sparkle/bin"
feed="appcast-$architecture.xml"

# The signing key travels over stdin, never as a process argument or log entry.
# generate_appcast also verifies that it matches the public key in the app.
printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$sparkle/generate_appcast" \
    --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$FREEMIND_UPDATE_REPOSITORY/releases/download/v$FREEMIND_RELEASE_VERSION/" \
    --link "https://github.com/$FREEMIND_UPDATE_REPOSITORY/releases/tag/v$FREEMIND_RELEASE_VERSION" \
    -o "$staging/$feed" "$staging"
printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$sparkle/sign_update" --ed-key-file - --verify "$staging/$feed"
python3 Scripts/verify-appcast.py "$staging/$feed" "$staging/$archive"
mv -f "$staging/$feed" "$output/$feed"
echo "$output/$feed"
