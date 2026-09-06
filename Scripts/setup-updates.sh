#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repository="${1:?Usage: bash Scripts/setup-updates.sh OWNER/REPO}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"

visibility=$(gh repo view "$repository" --json visibility --jq .visibility)
test "$visibility" = PUBLIC || { echo 'Make the release repository public before configuring updates.' >&2; exit 1; }
existing_key=$(gh variable list --repo "$repository" --json name,value --jq '.[] | select(.name == "SPARKLE_PUBLIC_ED_KEY") | .value')
swift package resolve --disable-sandbox --cache-path .build/cache
keys="$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
# Reuse this app's key across releases. Never regenerate it for each build.
"$keys" --account freemind
public_key=$("$keys" --account freemind -p)
if [ -n "$existing_key" ] && [ "$existing_key" != "$public_key" ]; then
  echo 'The repository uses a different signing key. Restore its original key before continuing; replacing it would break installed updaters.' >&2
  exit 1
fi
umask 077
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
"$keys" --account freemind -x "$temporary/private-key"
gh variable set SPARKLE_PUBLIC_ED_KEY --repo "$repository" --body "$public_key"
gh secret set SPARKLE_PRIVATE_ED_KEY --repo "$repository" < "$temporary/private-key"
echo "Update signing configured for $repository. The private key remains in your login Keychain under account freemind."
