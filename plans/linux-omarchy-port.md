# Native Linux / Arch / Omarchy port

Status: implementation in progress. Updated on 2026-09-08 on Arch Linux ARM.
The portable core/helper and native Swift + GTK4/VTE/GtkSourceView frontend run
in Hyprland. The workspace, files/editor, Git, notes, settings and terminal
workflows are implemented. Signed per-user updates and release packaging are
implemented; publication, clean-system validation and macOS CI remain pending.
See [the parity checklist](linux-parity-checklist.md) for implementation coverage
and the distinction between automated and manual validation.

## Objective

Build a native Linux version of Freemind that runs on Arch Linux, including
Omarchy, while maintaining the existing macOS application. Preserve the workspace,
terminal, Git, code editor, and Markdown notes workflows and keep the shared
`.freemind` project file formats compatible.

This is feasible, but requires a substantial UI port. The current application
cannot be built for Linux just by changing its target platform. Its SwiftUI and
AppKit interface, terminal view, desktop integration, and release pipeline depend
on macOS. The separate Swift core provides a useful foundation for sharing logic.

## Recommended direction

- Build a GTK4 frontend with VTE for embedded terminals. GTK supports native
  Wayland windows, making it a suitable candidate for Omarchy's Hyprland desktop.
- Share `FreemindCore`, including settings, palettes, workspace formats, Git and
  terminal behavior. Its Linux build and tests now pass.
- Retain tmux as the persistent session backend. VTE would launch a tmux attachment
  client in its PTY; tmux would continue to own the underlying shell or agent.
- Preserve the macOS frontend and share portable behavior and storage models.
- Signed per-user release archives support downloads and installation on quit.
  System/package-managed builds defer updates to their package manager. An Arch
  `PKGBUILD` and AUR publication remain separate distribution work.

The integration trial now uses Swift with a small C GTK4/VTE bridge in `Linux/`.
Swift actors call the shared core directly; GTK owns the main thread, and widget
updates are queued through GLib. The frontend is a separate Swift package, so a
core/helper build does not require GTK or VTE. `freemind-helper` continues to
handle hooks and launches; no service protocol was introduced.

## Source map and known portability work

Paths below are relative to the repository root.

| Area | Existing source | Required work |
| --- | --- | --- |
| Package configuration | `Package.swift` | Separate macOS targets, Sparkle dependency, Metal resources, and Apple linker flags from Linux builds. The macOS platform declaration is not the only blocker. |
| Models and storage | `Sources/FreemindCore/Models.swift`, `Storage.swift`, `AppSettings.swift`, `PaneGrid.swift` | Compile and test on Linux; preserve serialization and workspace schema compatibility. |
| Processes and helper | `Sources/FreemindCore/CommandRunner.swift`, `Sources/FreemindHelper/main.swift` | Replace unconditional `Darwin` imports with platform imports; verify POSIX calls, process cancellation, pipes, and helper execution. |
| Terminal backend and hooks | `Sources/FreemindCore/TerminalBackend.swift`, `HookConfiguration.swift` | Supply a Linux-compatible SHA-256 implementation, such as Swift Crypto; verify imports, socket handling, canonical paths, hook hashes, executable discovery, and shell defaults. |
| Git | `Sources/FreemindCore/GitService.swift` | Test existing command-based behavior on Linux; review executable path assumptions and preserve Git hooks, signing, and authentication behavior. |
| Terminal UI | `Sources/Freemind/TerminalView.swift`, `Vendor/SwiftTerm/` | Replace the AppKit terminal surface with VTE. Validate rendering and keyboard behavior instead of assuming feature parity. |
| Workspace lifecycle and file watching | `Sources/Freemind/WorkspaceModel.swift` | Separate portable orchestration from SwiftUI/AppKit. Replace CoreServices/FSEvents with Linux file monitoring, such as GIO or inotify. |
| Application and windows | `Sources/Freemind/AppStore.swift`, `FreemindApp.swift`, `Commands.swift` | Replace application lifecycle, bookmark handling, file dialogs, window tracking, and shortcuts. Use Linux configuration/state paths. |
| Views and editor | `Sources/Freemind/*View.swift`, `TextEditor.swift`, `WorkspaceSplit.swift` | Implement GTK equivalents for sidebar, pane layout, editor, Git diffs, notes, and settings; evaluate GtkSourceView for the editor. |
| Appearance | `Sources/Freemind/Theme.swift`, `NativeMaterials.swift`, `Resources/` | Carry over theme palettes and branding; adapt materials and icons to Linux desktop conventions. |
| Build and updates | `Scripts/build-backend.sh`, `build-app.sh`, `package-app.sh`, `Sources/Freemind/AppUpdater.swift` | Add Linux build/package paths. Existing scripts use Xcode, macOS compiler flags, codesign, otool, app bundles, and Sparkle. Prefer the system tmux package on Arch. |
| Tests | `Tests/FreemindCoreTests/` | Remove assumptions about bundled macOS tmux, `.build/debug/freemind-helper`, and `/bin/zsh`; run the core and session tests with Linux executables. |

## Start here on the Linux PC

1. Read this plan and any repository `AGENTS.md` instructions. Inspect the working
   tree before editing; do not overwrite unrelated work.
2. Record the actual architecture, distribution, session type, Swift toolchain,
   tmux, and Git versions. Confirm that a Wayland/Hyprland session is available
   for GUI testing. Do not assume that binaries built on the Mac are usable.
3. Verify current Arch packages and installation instructions for Swift, GTK4,
   VTE's GTK4 variant, and any selected bindings. Confirm the installed tmux
   version supports the backend's commands and configuration.
4. Make `FreemindCore` and `freemind-helper` independently buildable on Linux before
   implementing the full frontend. Keep Apple-only dependencies out of the Linux
   package graph.
5. Adapt and run the existing core tests, then build the minimal terminal UI
   described below. Record exact working build/run commands in the repository.

Useful initial inspection commands:

```sh
git status --short
uname -m
cat /etc/os-release
printenv XDG_SESSION_TYPE WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
command -v swift tmux git pkg-config
swift --version
tmux -V
git --version
```

Missing commands identify dependencies to install; the current macOS build
scripts are not Linux setup instructions. Verify toolchain support for the actual
Arch machine rather than assuming every official Swift Linux build targets Arch.

## Implementation milestones

### 1. Portable core and helper

- [x] Conditional package targets and dependencies allow a Linux core/helper build.
- [x] POSIX imports, hashing, paths, and shell/executable discovery work on Linux.
- [x] Existing storage, settings, Git, and terminal backend tests pass on Linux.
- [x] Tests discover the built helper and Linux tmux without macOS bundle paths.
- [ ] Shared changes still pass macOS checks through CI or an available Mac.

### 2. First usable Linux version

- [x] Open a folder and initialize/load its Freemind workspace.
- [x] Show multiple VTE terminal panes attached to distinct tmux sessions.
- [x] Resize and rearrange panes without losing their processes or terminal input.
- [x] Quit and relaunch the frontend, then reattach to the same surviving sessions.
- [x] Explicitly closing a pane stops its session; quitting the app preserves it.
- [ ] Launch Codex and consume status/approval events using the existing behavior.
- [ ] Verify keyboard input, clipboard, Unicode, colors, scrolling, mouse events,
  and terminal application rendering in a real Wayland/Hyprland session.

This milestone should establish that the chosen UI/core integration and terminal
behavior work before expanding to the complete application.

### 3. Workflow parity

- [x] Workspace sidebar, command palette, pane controls, and detached windows.
- [x] File explorer, code editing, selection comments, and external-edit conflicts.
- [x] Git status, diffs, staging, commits, branches, fetching, and pushing.
- [x] Markdown notes, autosave, preview, and conflict handling.
- [x] Settings, themes, dialogs, file monitoring, and desktop notifications.
- [x] Linux command shortcuts; editor and terminal input retain native bindings.
- [ ] Manually verify every shortcut against the user’s complete Hyprland bindings.
- [ ] Window restoration adapted to compositor control; do not assume macOS-style
  absolute window positioning is available on Wayland.

### 4. Packaging and release validation

- [ ] Reproducible Linux build instructions and CI coverage.
- [ ] Arch `PKGBUILD`, declared runtime dependencies, desktop entry, and app icon.
- [ ] Install, launch, upgrade, and remove the package on a clean Arch environment.
- [ ] Validate fractional scaling, fonts, focus, clipboard, and detached windows
  on the intended Omarchy machine.
- [x] Document package-manager updates, signed per-user updates and architectures.
- [x] Build/sign Linux release archives in CI when Linux signing keys are configured.
- [x] Generate a single-command GitHub installer, desktop launcher and release-page
  installation instructions; document installation in the repository README.
- [ ] Configure production Linux signing keys and publish the first Linux release.

## Behavior to preserve and verification limits

- Shared project metadata and notes should remain readable on both platforms.
  Machine registries, bookmarks, absolute paths, authentication, and
  `.freemind/local/` state are machine-specific and need separate handling.
  Shared workspace files do not transfer live processes between computers.
- Surviving tmux sessions retain their processes when the frontend exits.
  Backend loss or a reboot requires recovery from saved state and conversation
  identity; it cannot restore shell memory, running commands, or unsent input.
- Recovery must not resubmit the original prompt or resume a different pane's
  conversation. Preserve the current observation-only hook behavior.
- Reuse the existing tests for backend persistence, recovery, exit status,
  concurrent sessions, Git operations, and conflict handling. Keep live Codex
  verification separate because it requires an installed CLI and authentication.
- A Linux compile or headless test run does not establish GUI compatibility.
  Terminal behavior needs a real desktop test, and reboot recovery needs a real
  reboot test. Record what was actually verified as work proceeds.

## Verified environment and working commands (2026-09-08)

| Component | Verified on this machine |
| --- | --- |
| Distribution / architecture | Arch Linux ARM, `aarch64` (Omarchy Apple Silicon fork) |
| Desktop | Hyprland 0.56.2, native Wayland (`xwayland: false`) |
| Swift | 6.3.3, official Ubuntu 24.04 ARM64 toolchain |
| GTK / VTE | GTK 4.22.4; VTE GTK4 0.84.1 |
| tmux / Git | tmux 3.7c; Git 2.55.0 |

```sh
bash Scripts/build-linux.sh debug --core-only
bash Scripts/test-linux.sh
bash Scripts/build-linux.sh
bash Scripts/test-linux-ui.sh  # real Wayland session, PyGObject, session D-Bus
bash Scripts/run-linux.sh /path/to/workspace
```

Use `bash Scripts/build-linux.sh release` and
`FREEMIND_CONFIGURATION=release bash Scripts/run-linux.sh /path/to/workspace`
for a release build. The helper is copied beside the frontend executable.
`FREEMIND_BUILD_JOBS` changes the default six compiler jobs.

The standard dependencies are Swift 6.1+, GTK4 4.14+, GTK4 VTE, GtkSourceView 5, Git, tmux,
a C/C++ toolchain, and pkg-config. On Omarchy the native package command is
`omarchy pkg add gtk4 vte4 gtksourceview5 tmux git clang pkgconf python openssl`. Swift needs a toolchain
compatible with the machine's architecture and distribution; do not install the
unrelated OpenStack `swift` package.

This machine initially had no Swift or VTE. The system VTE installation could
not authenticate. For this trial, dependencies were staged under ignored
`.build-support/` instead:

- Swiftly installed the signed Swift 6.3.3 Ubuntu 24.04 ARM64 toolchain in
  `.build-support/swiftly/toolchains/6.3.3`. Its home, binary, and toolchain paths
  were all set explicitly; no shell profile was edited.
- Arch Linux ARM packages `vte4` 0.84.1 and `libxml2-legacy` 2.13.9 were extracted
  under `.build-support/linux-deps/root`. Both package signatures were verified
  against the installed Arch Linux ARM keyring.
- Ubuntu's ARM64 `libncurses6` 6.4+20240113-1ubuntu2.2 supplies the separate
  `libncurses.so.6` required by that toolchain. Arch's system libraries were
  not replaced or symlinked to incompatible sonames.
- `Scripts/linux-env.sh` locates this optional local toolchain and libraries;
  normally it uses installed tools. The staged VTE pkg-config file has its
  prefix rewritten to the local `root/usr` directory.

These ignored downloads are local development dependencies, not a distributable
package. A clean Arch bootstrap and runtime packaging remain release work. The
ARM toolchain prints warnings that its backtrace helper cannot protect memory
on this machine; compilation and the exercised runtime behavior still pass.

### Completed implementation and validation

- Root package graph excludes Sparkle, AppKit, SwiftUI, SwiftTerm/Metal, and Apple
  linker settings on Linux. macOS retains its frontend and exact Sparkle pin.
  The lockfiles currently reflect the Linux graph; resolving on macOS regenerates
  the platform-specific pins.
- Linux hashing uses pinned Swift Crypto 4.5.2. Fixed hook and socket hash
  fixtures verify compatibility with the existing serialized identities.
- Linux command execution uses `posix_spawn` and direct `waitpid` rather than
  Foundation's inherited-socket exit detection, which hung after tmux daemonized.
  Spawned children receive an unblocked signal mask so tmux can observe SIGCHLD.
  Input/output, timeout escalation, cancellation, and early stdin closure have
  dedicated regression tests.
- **49 core tests: 48 passed, 1 skipped, 0 failures.** The skipped test is the
  opt-in authenticated Codex response/resume test. The passing suite includes
  Git operations, settings/storage, exit events, process persistence, backend
  loss recovery, and 17 concurrent terminal sessions.
- `Linux/Sources/FreemindLinux/Main.swift` handles workspace loading, pane
  lifecycle, scoped hook events, periodic checkpoints, layout conflict checks,
  and an XDG state file (`$XDG_STATE_HOME/freemind/linux.json`, or
  `~/.local/state/freemind/linux.json`) recording open workspaces, selection and
  sidebar preferences. Workspace-local restoration retains view and split state.
- The GTK bridge provides shared light/dark palettes, a resizable workspace sidebar,
  focusable terminal rows, compact pane menus, responsive grid positions,
  scrolling for larger grids, and matching VTE colors. Reordering changes grid
  coordinates without destroying terminal widgets.
- Linux shortcuts: **Ctrl+Shift+O** open folder, **Ctrl+Shift+T** new shell,
  **Ctrl+Shift+N** new Codex, **Ctrl+Shift+Q** quit, and **Ctrl+Shift+C/V** copy/paste.
  Pane menus provide reordering and reconnect/restart; closing a pane stops it.
- **Native GTK/VTE lifecycle smoke test passed** (`Tests/LinuxUITests/smoke.py`):
  two shell panes attach through VTE, Unicode output is captured, reordering
  retains attachment-client PIDs, quit/relaunch retains shell PIDs and unsent
  input, and explicitly closing a pane stops only its session. GTK logs contain
  no criticals or warnings. The expanded test also covers settings and defaults,
  workspace switching, editor drafts and conflicts, notes autosave, Git staging,
  commits and branch switching, manual split ratios, sidebar restoration, and
  detaching/reattaching without replacing VTE clients. It uses disposable workspaces and native
  GActions over the session D-Bus; it does not inject a Codex prompt.
- A real Wayland window, workspace opening, multiple embedded Codex/shell panes,
  and rendered Codex TUI colors were observed on this Hyprland machine. The user
  exercised the prototype. A completed authenticated conversation and exact
  conversation resume have not been verified on Linux.
- `.github/workflows/check.yml` adds Linux x86_64/ARM64 core tests and frontend
  builds, plus macOS checks. This workflow has been added locally but has not run
  on GitHub; macOS validation remains unchecked.

### Next work

Finish the manual terminal matrix (clipboard, Unicode, mouse reporting, scrolling,
keyboard-driven input and resize, and fractional scaling), validate live Codex
status/approval/recovery, and exercise backend loss with the GUI. Manual splits,
file editing, Git/notes, settings/themes and detached panes are implemented.
Configure production signing, publish the first Linux release, validate clean
installs and macOS CI, and prepare Arch package-manager distribution separately.

## References

- [Swift on Linux](https://www.swift.org/install/linux/)
- [Swiftly installation and local paths](https://www.swift.org/install/linux/swiftly/)
- [Arch Linux ARM GTK4 VTE package](https://archlinuxarm.org/packages/aarch64/vte4)
- [Official Swift container tags and architectures](https://hub.docker.com/_/swift)
- [Swift Crypto 4.5.2](https://github.com/apple/swift-crypto/releases/tag/4.5.2)
- [SwiftUI's Apple platform scope](https://developer.apple.com/swiftui/)
- [GTK4 Wayland support](https://docs.gtk.org/gtk4/wayland)
- [VTE GTK4 terminal widget](https://gnome.pages.gitlab.gnome.org/vte/gtk4/class.Terminal.html)
- [Omarchy platform overview](https://omarchy.org/manual/omarchy-on/)

## Suggested resume prompt

> Read `plans/linux-omarchy-port.md` and implement the native Linux port from this
> Arch/Omarchy machine. Start with the portable Swift core and helper, then build
> the GTK4/VTE terminal milestone. Preserve macOS support and workspace format
> compatibility. Verify the current environment and dependencies, test on Linux,
> and update the plan with completed work, working commands, and remaining issues.


### Settings and updates

- Open Settings with the gear button or **Ctrl+,**. Appearance, all 12 built-in
  palettes, independent terminal themes, custom light/dark themes and ANSI colors,
  transparency, Codex options, workspace defaults and update preferences are wired.
- Settings live in `$XDG_CONFIG_HOME/freemind` (default `~/.config/freemind`).
  `settings.json` and `Themes/themes.json` use the shared formats. The editor
  scheme under `styles/` is generated from the selected app palette. Other windows
  pick up valid settings and theme changes. Invalid theme edits keep working colors.
- New workspaces inherit global defaults; existing workspaces retain their saved
  defaults. Configure a terminal through Commands → Configure New Terminal.
- GtkSourceView 5.20.0 was staged locally from the signed Arch Linux ARM package;
  its signature was verified with the Arch Linux ARM keyring. Standard installs
  use the `gtksourceview5` system package.
- **19 updater/installer tests pass**, covering signed manifests, tampering, wrong keys and
  architectures, rollback rejection, unsafe archive paths, symlinks/devices,
  installation identity, offline installation, preservation of older helpers,
  first install, upgrades, reruns, existing command preservation and signing setup.
- **Real packaging smoke test passes**: native app/helper, bundled Swift runtime,
  an ephemeral signing key, a signed archive, the standalone piped installer,
  repeat installation and desktop/command launchers.
  Nothing was published and no production signing key was generated.
- `Scripts/setup-linux-updates.py` configures GitHub signing without printing the
  private key; `Scripts/build-linux-installer.py` generates the release's readable
  `install.sh`. The publishing job uploads it and `INSTALL.md`, uses installation
  instructions as the release body, and waits for both Linux architectures.
- [Linux release instructions](../Linux/README.md) cover dependencies, installation,
  signing and GitHub release configuration. Development builds do not replace
  themselves from a public feed. Auto-update becomes available after installing a
  signed Linux release; package-managed builds defer to their package manager.
