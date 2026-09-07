# Freemind

A local macOS workspace for Codex CLI terminals, files, Git, and Markdown notes. Built with SwiftUI and AppKit. Requires macOS 14 or newer; macOS 26 adds native Liquid Glass. Freemind has no account. Install and sign in to Codex CLI separately.

## Build and launch

Requires Xcode 26 (including Icon Composer), Swift, and the command line tools:

```sh
bash Scripts/build-app.sh release
open dist/Freemind.app
```

The first build downloads the pinned tmux/libevent sources and verifies their checksums. Swift Package Manager also downloads the pinned, checksummed Sparkle framework; SwiftTerm is vendored. The script compiles the layered icon with Apple's asset compiler, includes legacy macOS icon renditions and licenses, and signs the app locally. It is a development build, not notarized for distribution. Asset compilation requires access to Xcode's local rendering services; an agent filesystem sandbox may need permission to run the build.

## Share the app

```sh
bash Scripts/package-app.sh
```

This builds a release app for the build Mac's architecture and creates `dist/Freemind-0.1.0-macOS-arm64.zip` on Apple Silicon (`x86_64` on Intel), plus a SHA-256 checksum. The zip includes Freemind.app, an Applications shortcut, and first-launch instructions. Recipients unzip it, drag Freemind into Applications, and open it there. They need macOS 14 or newer and a matching Mac architecture. Codex CLI and its login are separate; Git features require Git.

The app is locally signed, without Developer ID signing or Apple notarization. On first launch, recipients may need **System Settings → Privacy & Security → Open Anyway**, as described in [Apple's instructions](https://support.apple.com/en-us/102445). A distribution without this extra approval requires a Developer ID Application certificate and notarization.

## Automatic updates and GitHub Releases

Release builds check for updates automatically, download signed updates, and install them when you quit. Use **Freemind → Check for Updates…** or change update preferences in Settings. Local development builds leave updating disabled.

The included GitHub Action builds Apple Silicon and Intel releases when you push a version tag. It hosts the ZIPs and signed update feeds directly on your public GitHub repository. See [RELEASING.md](RELEASING.md) for the one-time signing-key setup and release commands. Existing installations need one manual upgrade to the first release with updater support.

## Working

Open a folder with **⌘O**. Expand a workspace in the sidebar to see and focus its terminals. New terminals automatically form a grid that adapts to the window width. Use the pane menu for explicit splits, history, restart/resume, or a separate window. Closing a terminal stops its process; closing a window or quitting the app keeps terminals running.

A terminal that exits successfully closes its pane and any detached window automatically. Failed exits remain visible with their status so you can inspect the error or restart. Saved output remains in the workspace.

The Code tab includes a file explorer and syntax-highlighted editor. Select code and use **Comment → Codex** to create a new terminal with the file, line range, selected text, and your instruction. The original prompt is not resubmitted when recovering a pane. Drag files into a terminal to paste quoted paths without submitting them.

Opening or closing files and changing the automatic grid preserve the existing native terminal views. Layout changes resize the PTYs without detaching or remounting them. Debug builds support `FREEMIND_TRACE_TERMINALS=1` to log mounts and sizes for performance checks.

The Git tab shows staged, unstaged, and untracked files, unified or split diffs, staging, commits, and pushes. Commits include staged changes and use the repository's Git identity, hooks, signing, and authentication. First push asks for the remote and branch. A failed push keeps the successful local commit. Fetch refreshes remote tracking information. If your workspace is a subfolder, Git operations apply to the displayed repository root.

The active Git branch stays beside the workspace name in the top bar on every tab. Click it, or the branch button in the Git tab, to search and switch local or fetched remote branches. Selecting a remote branch creates a local tracking branch. Git blocks switches that would overwrite local changes or use a branch already checked out in another worktree. Errors remain visible across tabs with selectable, scrollable details.

Notes are ordinary Markdown files with autosave and preview. Conflicting external edits preserve the local draft and offer Reload or Save a Copy.

## Keyboard shortcuts

**⌘K** opens a searchable command list with every shortcut; **⇧⌘/** opens the same reference. The macOS menu bar also lists commands.

| Shortcut | Action |
| --- | --- |
| ⌘T / ⇧⌘T / ⌥⌘T | New Codex / shell / configured terminal |
| ⌘W / ⇧⌘W | Close focused panel / window |
| ⌘1 / ⌘2 / ⌘3 | Code / Git / Notes |
| ⌘P / ⌘B | Find file / toggle explorer |
| ⌘S / ⇧⌘L | Save / comment on selection |
| ⌘D / ⇧⌘D | Split right / below |
| ⌥⌘← / ⌥⌘→ | Previous / next terminal |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next workspace |
| ⇧⌘M / ⌥⌘A | Maximize / auto arrange |
| ⌘+ / ⌘− / ⌘0 | Terminal text size |
| ⇧⌘R | Refresh Git |
| ⌘Return / ⇧⌘Return / ⌥⌘P | Commit / commit and push / push |

## Workspace storage and recovery

Version `.freemind/workspace.json`, `layout.json`, `comments.json`, and `notes/` in Git. `.freemind/local/` is ignored automatically and holds pane-specific Codex state, terminal checkpoints, window positions, and editor drafts. The app's small machine registry stores folder references so it can find your workspaces after launch. tmux sockets use short OS temporary paths. Existing Codex authentication is reused from machine-level storage; do not force-add `.freemind/local` to Git.

Workspace defaults and each pane's launch options include model, profile, reasoning effort, approval/sandbox settings, search, inline display, provider, extra directories, and advanced arguments. Workspace trust defaults on and is configurable. This allows workspace-local Codex configuration to load; it does not disable Codex's sandbox or tool approvals. Only Freemind's generated observation hooks are automatically trusted.

**Freemind → Settings → Workspace Defaults** sets the initial terminal options for new workspaces. Existing workspaces keep their saved defaults; choose **Use Global Defaults** in a workspace’s **Terminal Defaults** sheet, then save, to copy the current global options. Existing panes retain their launch options.

**Settings → Appearance** offers Forest, Ocean, Violet, and Graphite plus VS Code, One Dark / Light, Dracula, GitHub, Nord, Solarized, Tokyo Night, and Catppuccin-inspired themes. Every theme supports System, Light, or Dark app appearance. Terminals can match the app or use their own theme and Light/Dark mode, including dark terminals in a light app. Colors update in place across windows, editors, and terminals. Terminal programs can also draw their own explicit colors. App settings are stored locally beside the application registry in `settings.json`. The editor and terminal ANSI palette follow the selected theme; light variants and some colors are adapted for Freemind. [Theme credits and licenses](Resources/licenses/Theme-inspirations.txt) are included in the app.

Use **New Theme…** to start from the current palette and customize its light and dark colors, syntax highlighting, and 16 terminal ANSI colors. **Save & Use** selects the result; custom themes also appear in the independent terminal theme picker. **Edit Theme** lets you revise an existing custom theme.

**Open Theme Configuration** opens `~/Library/Application Support/Freemind/Themes/themes.json` in a dedicated workspace, alongside `THEMES.md` and `AGENTS.md` with the format and editing instructions. **Create with Codex…** takes a theme name and description, selects a starter theme, and opens a Codex terminal in that workspace with instructions to update it. This uses your existing Codex CLI installation, login, and workspace defaults. Valid configuration saves reload automatically. Invalid JSON, colors, or duplicate IDs show an error and keep the last valid colors; the editor detects conflicting external theme edits before saving. Removing a selected theme falls back to its built-in base with a visible message. Existing settings and built-in themes remain compatible.

Across app quit/relaunch, surviving tmux sessions retain their processes and input. After backend loss or a Mac reboot, the app restores layouts and saved output and resumes each recorded Codex conversation by its own ID. A reboot cannot preserve running commands, shell memory, or unsent terminal input. Empty Codex sessions gain their durable conversation identity on the first prompt. Historical output is labeled separately. A real reboot must be tested by the user.

## Verification

```sh
swift test --disable-sandbox --cache-path .build/cache
FREEMIND_LIVE_CODEX=1 swift test --disable-sandbox --cache-path .build/cache
```

The regular suite uses temporary repositories and local bare remotes, validates recovery/storage, grid sizing, terminal environments, and 17 concurrent terminal sessions. Tests require local Unix sockets. The opt-in test uses your installed Codex and login for a minimal response, then kills the test backend and checks exact conversation recovery. It never edits a real project.

Icon artwork is in `Resources/Freemind.icon` with editable SVG sources in `Resources/IconArtwork`. The silver leaf uses separate translucent layers. Icon Composer supplies lighting, glass effects, platform masking, and Default/Dark/Mono appearances.

The workspace tree uses native disclosure rows, hiding the disclosure control for empty workspaces. Hook events drive a busy spinner, completion checkmark, and yellow approval indicator. Each new approval event plays the macOS Glass sound once. File, Git, Notes, and editor divider positions are saved with the workspace.
