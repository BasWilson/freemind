# Native Linux / Arch / Omarchy port

Status: planning only. Written on 2026-09-07 after inspecting the macOS source.
No Linux implementation, build, or runtime verification has been completed.

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
- Retain and port `FreemindCore` where practical. Swift supports Linux, but this
  particular core has not yet been compiled there.
- Retain tmux as the persistent session backend. VTE would launch a tmux attachment
  client in its PTY; tmux would continue to own the underlying shell or agent.
- Preserve the macOS frontend and share portable behavior and storage models.
- Distribute through an Arch `PKGBUILD` and pacman package. Consider AUR publication
  after the package and application have been validated.

GTK4/VTE is a recommendation, not a completed technology selection. The frontend
language and connection to the Swift core still need a small integration trial.
Evaluate Swift GTK bindings or a thin C interoperability layer first. A frontend
in another language communicating with a local Swift service is another option,
but introduces a protocol and process lifecycle to maintain. The existing
`freemind-helper` handles hooks and launches; it is not already such a service.

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

- [ ] Conditional package targets and dependencies allow a Linux core/helper build.
- [ ] POSIX imports, hashing, paths, and shell/executable discovery work on Linux.
- [ ] Existing storage, settings, Git, and terminal backend tests pass on Linux.
- [ ] Tests discover the built helper and Linux tmux without macOS bundle paths.
- [ ] Shared changes still pass macOS checks through CI or an available Mac.

### 2. First usable Linux version

- [ ] Open a folder and initialize/load its Freemind workspace.
- [ ] Show multiple VTE terminal panes attached to distinct tmux sessions.
- [ ] Resize and rearrange panes without losing their processes or terminal input.
- [ ] Quit and relaunch the frontend, then reattach to the same surviving sessions.
- [ ] Explicitly closing a pane stops its session; quitting the app preserves it.
- [ ] Launch Codex and consume status/approval events using the existing behavior.
- [ ] Verify keyboard input, clipboard, Unicode, colors, scrolling, mouse events,
  and terminal application rendering in a real Wayland/Hyprland session.

This milestone should establish that the chosen UI/core integration and terminal
behavior work before expanding to the complete application.

### 3. Workflow parity

- [ ] Workspace sidebar, command palette, pane controls, and detached windows.
- [ ] File explorer, code editing, selection comments, and external-edit conflicts.
- [ ] Git status, diffs, staging, commits, branches, fetching, and pushing.
- [ ] Markdown notes, autosave, preview, and conflict handling.
- [ ] Settings, themes, dialogs, file monitoring, and desktop notifications.
- [ ] Linux shortcuts that coexist with terminal input and Hyprland bindings.
- [ ] Window restoration adapted to compositor control; do not assume macOS-style
  absolute window positioning is available on Wayland.

### 4. Packaging and release validation

- [ ] Reproducible Linux build instructions and CI coverage.
- [ ] Arch `PKGBUILD`, declared runtime dependencies, desktop entry, and app icon.
- [ ] Install, launch, upgrade, and remove the package on a clean Arch environment.
- [ ] Validate fractional scaling, fonts, focus, clipboard, and detached windows
  on the intended Omarchy machine.
- [ ] Document package-manager updates and supported architectures.

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

## References

- [Swift on Linux](https://www.swift.org/install/linux/)
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
