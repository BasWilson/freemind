# Freemind for Linux

Native GTK4, VTE and GtkSourceView, with the same workspace formats and tmux backend
as the Mac app. Linux support is under active validation on Omarchy/Hyprland.

## Install a GitHub release

After the first Linux release is published:

```sh
curl -fsSL https://github.com/BasWilson/freemind/releases/latest/download/install.sh | bash
```

Python 3.11+ and curl must be available. The script selects x86_64 or ARM64,
offers to install missing runtime dependencies through pacman (Arch/Omarchy) or
apt (Ubuntu 24.04+), verifies the release's Ed25519 signature and checksum, and
creates a per-user installation and desktop launcher. No source build is needed.
It requires glibc 2.39+; other distributions must provide the dependencies below.

Run as your desktop user; only system dependency installation uses sudo. Open
**Freemind** from your app launcher or use `~/.local/bin/freemind /path/to/workspace`.
Add `~/.local/bin` to PATH if it is not already there. Codex CLI and login remain
separate. Automatic update preferences are in Settings.

To inspect or customize the installer:

```sh
curl -fL https://github.com/BasWilson/freemind/releases/latest/download/install.sh -o freemind-install.sh
less freemind-install.sh
bash freemind-install.sh --help
bash freemind-install.sh --prefix "$HOME/Applications/Freemind" --no-deps
```

`--no-deps` checks dependencies without running a package manager. Rerunning the
installer upgrades an existing installation with the same signing identity,
never downgrades, and repairs its launcher. An existing unrelated `freemind`
command is preserved; the desktop entry still launches the installed app.
Installer downloads are pinned to their release version, so an older release's
instructions continue to install that version even after another is published.

## Develop and run

Install Swift 6.1+, GTK4 4.14+, VTE's GTK4 variant, GtkSourceView 5, tmux, Git,
pkg-config and a C/C++ toolchain. Updates additionally require Python 3.11+ and
OpenSSL 3+. On Arch/Omarchy, the native packages are `gtk4`, `vte4`, `gtksourceview5`,
`tmux`, `git`, `pkgconf`, `clang`, `python` and `openssl`. Use a Swift language
toolchain; the OpenStack package named `swift` is unrelated.

```sh
bash Scripts/build-linux.sh
bash Scripts/run-linux.sh /path/to/workspace
bash Scripts/test-linux.sh
bash Scripts/test-linux-ui.sh  # real Wayland session, PyGObject and session D-Bus
python3 -m unittest discover -s Tests/LinuxUpdateTests -v
```

`Scripts/linux-env.sh` also recognizes the ignored local dependency/toolchain
staging described in the [port plan](../plans/linux-omarchy-port.md).

## Workspaces and settings

Opening another folder adds it to the sidebar. Click a workspace to switch; its
shells remain alive. Drag sidebar dividers to resize them. Workspace menus rename,
pin, reorder, remove references and open separate windows. Removing a sidebar
reference keeps the folder and sessions intact.

Code, Git and Notes are available in the top bar. The file tree supports nested
folders, hidden files, search, external opening and file dragging. The editor has
syntax highlighting, line numbers, undo, search, explicit save, crash drafts,
external-edit conflict detection and selection comments that start a Codex pane.
Notes autosave and have a Markdown preview. Git supports unified/split diffs,
staging, unstaging, commits, local/remote branch switching, fetching and pushing;
Git performs authentication and runs the repository's existing hooks.

Terminal menus offer rename, split right/below, reorder, maximize, detach,
reconnect/resume, saved output and history export. Manual layouts use draggable
split handles. Normal quit leaves tmux sessions running. Commands also contains
**Quit and Stop All Terminals**, which asks before stopping them.

Settings exposes app/terminal appearance, all 12 shared palettes, custom themes,
window opacity, every Codex launch option, defaults and updates. Global defaults
seed new workspaces; existing workspace and pane options remain intact. Window
transparency is supported; compositor blur is controlled by the desktop.

| Shortcut | Action |
| --- | --- |
| Ctrl+, | Settings |
| Ctrl+Shift+K | Commands and shortcut list |
| Ctrl+Shift+P | Quick open a file |
| Ctrl+Shift+O | Open workspace |
| Ctrl+Shift+T / N | New shell / Codex |
| Ctrl+Alt+T | Configure a new terminal |
| Ctrl+Shift+1 / 2 / 3 | Code / Git / Notes |
| Ctrl+Shift+B | Toggle file tree |
| Ctrl+Alt+Up / Down | Previous / next workspace |
| Ctrl+Alt+Left / Right | Previous / next terminal |
| Ctrl+Shift+S | Save file or note |
| Ctrl+Shift+L | Comment on selected code |
| Ctrl+Shift+M | Maximize / restore terminal |
| Ctrl+Shift+W | Close focused terminal with confirmation |
| Ctrl++ / Ctrl+− / Ctrl+0 | Terminal font size |
| Ctrl+Shift+C / V | Terminal copy / paste |
| Ctrl+Shift+Q | Quit and keep sessions running |

Machine state is stored in `$XDG_STATE_HOME/freemind/linux.json` and settings in
`$XDG_CONFIG_HOME/freemind` (standard `~/.local/state` / `~/.config` fallbacks).
Per-workspace files, notes, defaults, pane layouts and restoration remain under
`.freemind`. Custom themes use `Themes/themes.json` and reload valid external saves.

## Signed releases and automatic updates

Supported release architectures are `x86_64` and `aarch64`. Build releases in the
pinned `swift:6.3.3-noble` environment; binaries target Ubuntu 24.04's glibc baseline.
Archives include Swift runtime libraries, the app/helper, the update client and
licenses. GTK4, VTE, GtkSourceView, Git and tmux remain system dependencies. These
archives are not AppImages and do not include an entire desktop stack.

Extract the matching release archive from the project's GitHub Releases page and
run `bash install.sh` inside it. Installation is per user, without sudo. The
installer creates a desktop entry and `~/.local/bin/freemind`. If that launcher
already exists it is left untouched; the installed app can be launched through
`~/.local/share/freemind/current/launch`. An optional first installer argument
changes the install root.

Releases live under `versions/<version>` with an atomic `current` symlink. Signed
updates are checked daily and can be downloaded in Settings. Automatic downloads
install locally when quitting. Signature, archive size, SHA-256, platform and
version checks precede extraction. Extraction rejects links, devices and unsafe
paths. Installation verifies the cache again and preserves the previous release
on failure. Older directories are deliberately retained: surviving tmux hooks
may still reference the helper from their original release.

Development builds have no update feed and do not replace the working tree.
Builds installed by a package manager never self-replace system files. Production
updates require a published Linux release and the signing setup below; the local
packaging test uses an ephemeral test key and does not enable production updates.

### Configure the release pipeline

From this checkout, sign in to GitHub and configure signing once:

```sh
gh auth login
python3 Scripts/setup-linux-updates.py BasWilson/freemind
```

This creates or reuses `~/.local/share/freemind-release/linux-ed25519.key` with
owner-only permissions, stores the public key in the repository Actions variable
and sends the private key through stdin to the repository secret. Keep a secure
backup of the private file. It refuses to replace a different existing signing
identity. Use `--key /secure/path/existing.key` to restore an existing key.

For manual configuration instead:

Generate the key once and store the private file outside this repository:

```sh
python3 Scripts/generate-linux-update-key.py /secure/path/freemind-linux.key
```

Set repository variable `LINUX_PUBLIC_ED_KEY` to the public value printed by the
script, and repository secret `LINUX_PRIVATE_ED_KEY` to the private file's contents.
Keep the private key backed up; existing installations trust its corresponding
public key. Linux uses a separate Ed25519 key from the Mac Sparkle feed.

The existing tag release workflow builds and signs both Linux architectures when
`LINUX_PUBLIC_ED_KEY` is configured. Without that variable it continues to publish
Mac releases only. Linux failures block publication of an incomplete combined
release. Each Linux release publishes:

- `Freemind-VERSION-Linux-ARCH.tar.gz` and `.sha256`
- `linux-ARCH.json` and detached `linux-ARCH.json.sig`
- `install.sh`, the self-contained installer with the pinned public key
- `INSTALL.md`, also displayed on the GitHub release page

The README's stable installer URL uses GitHub's
[latest release asset link](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).
No GitHub Pages site or separate hosting service is needed. Both Linux archives
must be present before the workflow publishes the release and installer.

To package locally, export `FREEMIND_RELEASE_VERSION`,
`FREEMIND_UPDATE_REPOSITORY` (`owner/repo`), `LINUX_PUBLIC_ED_KEY` and
`LINUX_PRIVATE_ED_KEY`, then run `bash Scripts/package-linux.sh`. Do not put private
keys in shell history. `SOURCE_DATE_EPOCH` controls archive timestamps.

For an isolated real-binary packaging check after a debug build:

```sh
source Scripts/linux-env.sh
python3 Tests/LinuxUpdateTests/packaging_smoke.py
```

An Arch PKGBUILD/AUR release and clean-system installation tests remain packaging
work. macOS and CI results must be checked on their actual runners; Linux GUI
tests alone do not establish Mac compatibility or complete terminal emulation QA.
