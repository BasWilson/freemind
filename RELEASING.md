# GitHub Releases and automatic updates

Freemind hosts its installers and signed update feeds on GitHub Releases. macOS
uses [Sparkle](https://sparkle-project.org/documentation/); Linux uses signed
per-user archives and a single-command installer. Both support checking daily,
downloading updates and installing when the app quits. Terminal sessions keep
running through the existing save/checkpoint path.

## One-time setup

1. Create a **public** GitHub repository and push this project, including `.github/workflows/release.yml`, `Package.resolved`, and the vendored SwiftTerm sources. Push the default branch before tagging a release. `.freemind/local/`, build output, and signing keys must stay out of Git.
2. Sign in with `gh auth login` if needed, then run:

   ```sh
   bash Scripts/setup-updates.sh OWNER/REPO
   ```

   This generates or reuses a Sparkle Ed25519 key in your login Keychain under account `freemind`. It saves the public key as the repository Actions variable `SPARKLE_PUBLIC_ED_KEY` and the private key as the Actions secret `SPARKLE_PRIVATE_ED_KEY`. The temporary private-key export is removed automatically. macOS may ask you to allow Keychain access.

   Keep a secure backup of this key. All releases must use the same key; changing it without a migration prevents existing installations from updating. To export a backup to a secure location, use `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account freemind -x /secure/location/freemind-update-key`.
3. Ensure GitHub Actions is enabled. The workflow uses the repository's built-in `GITHUB_TOKEN` with `contents: write` only for the publishing job. No hosting service, Pages site, or personal access token is needed by the workflow.

The release repository is inferred from `github.repository`. No owner or repository name needs to be hardcoded in the app. Installed builds retain that repository URL, so keep it stable after the first release.

### Enable Linux releases

On Linux, configure the separate Linux signing key:

```sh
gh auth login
python3 Scripts/setup-linux-updates.py BasWilson/freemind
```

The setup script creates or reuses
`~/.local/share/freemind-release/linux-ed25519.key`, keeps it readable only by
your user, and sets Actions variable `LINUX_PUBLIC_ED_KEY` and secret
`LINUX_PRIVATE_ED_KEY`. Back up that file securely; use `--key PATH` to restore an
existing key. The script refuses to rotate a configured key automatically.
It never prints the private key or puts it in a command-line argument.

With the Linux public key configured, every version tag also builds x86_64 and
ARM64 Linux archives on Ubuntu 24.04 runners. The publishing job checks that both
archives and signed manifests exist, generates `install.sh` with the pinned
public key, and publishes installation instructions as the release body and
`INSTALL.md`. Publishing waits for the build jobs to finish and requires both
macOS builds to pass. If either Linux build fails, macOS still publishes without
Linux artifacts or installation instructions; the failed Linux jobs remain
visible in Actions. Without a Linux public key, the workflow releases macOS only.

After the first Linux release, users install with:

```sh
curl -fsSL https://github.com/BasWilson/freemind/releases/latest/download/install.sh | bash
```

The installer detects the CPU architecture, installs missing dependencies via
pacman or apt, verifies the signed archive and creates the desktop launcher.
Python 3.11+ and curl must already be installed. Freemind itself never installs as
root. See [Linux installation and packaging](Linux/README.md) for requirements,
custom prefixes, manual archives and the local packaging test.

## Publish a version

Commit and push the app changes, then push a stable version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

For the next release, use a higher version such as `v0.1.1`. Tags must use `vMAJOR.MINOR.PATCH`; prerelease tags are rejected. The tag sets both the displayed app version and Sparkle's comparison version. The source `Info.plist` does not need a version edit.

The **Release Freemind** Action:

1. Builds and tests native Apple Silicon and Intel apps on macOS 26 runners.
2. Bundles Sparkle and its installer services, tmux, icons, and licenses.
3. Creates first-install ZIPs, app-only update ZIPs, and SHA-256 checksums.
4. Signs the update archives and architecture-specific XML feeds with your Ed25519 key, then validates their metadata and feed signatures.
5. When Linux signing is configured, builds and tests both Linux architectures,
   bundles their Swift runtime, and signs their bounded JSON manifests.
6. Uploads all architectures, installation instructions and the Linux installer
   to a draft release, then publishes it once every asset is present. A failed
   upload leaves a resumable draft; rerun the failed job. Published versions
   cannot be overwritten by this workflow.

Download `Freemind-VERSION-macOS-arm64.zip` for Apple Silicon or `Freemind-VERSION-macOS-x86_64.zip` for Intel. The `-update.zip` assets are used by Sparkle. Feeds are served directly from:

```text
https://github.com/OWNER/REPO/releases/latest/download/appcast-arm64.xml
https://github.com/OWNER/REPO/releases/latest/download/appcast-x86_64.xml
```

Keep the latest release's ZIPs and feeds together. Publishing another stable release manually without the feeds would break these URLs. A manual workflow run must select an existing version tag. A branch run does not publish.

## Signing and first installation

Update archives and feeds are authenticated with Sparkle's Ed25519 signatures. Downloads are verified before extraction. The app retains the existing local/ad-hoc Apple code signing; it is **not Developer ID signed or notarized**. First installation can still require **System Settings → Privacy & Security → Open Anyway**. Sparkle signing does not remove that macOS requirement. Developer ID signing and notarization can be added separately when you have an Apple Developer account and certificate.

Existing builds made before the updater was added need one manual installation of a GitHub release. Subsequent releases use the updater. Local builds without release configuration do not start Sparkle or contact GitHub.

## Local verification

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
bash Scripts/package-app.sh
python3 Tests/ReleaseTests/signing_smoke.py
swift test --disable-sandbox --cache-path .build/cache
```

For a local build that follows your public feed, provide `FREEMIND_RELEASE_VERSION`, `FREEMIND_UPDATE_REPOSITORY=OWNER/REPO`, and `SPARKLE_PUBLIC_ED_KEY` when running `Scripts/package-app.sh`. Feed generation additionally requires `SPARKLE_PRIVATE_ED_KEY` and uses `bash Scripts/generate-appcast.sh`. Do not put the private key in source files or command-line arguments.

Before distributing widely, install the first published version into Applications, publish a higher version, and use **Check for Updates…** to verify download, install, relaunch, and terminal recovery on a real Mac. This final check requires two actual GitHub releases; a local build alone cannot verify the hosted update path.
