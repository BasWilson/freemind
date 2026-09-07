# Verification

Verified on macOS 26.6.2, Apple Silicon, Xcode 26.6 / Swift 6.3.3, with installed Codex CLI 0.153.3. The deployment target is macOS 14; older macOS versions were not available for GUI testing.

## Terminal performance and lifecycle

- Native terminal mount/resize diagnostics during file opening and closing with one and three panes recorded no remounts and one final resize per affected pane. No zero-sized PTY resizes were sent. Adding panes to the automatic grid retained existing views.
- The user confirmed that the updated UI looks good and that Finder file drops paste paths into terminals.
- A real shell exit in a detached QA window removed the pane from persisted layout in 0.393 seconds. Accessibility inspection confirmed that its window closed and its sidebar row disappeared. Other terminal process IDs were unchanged. The inline shell exit also removed its pane automatically.
- Integration tests cover normal exit versus status 7, event delivery through paths containing spaces and quotes, retained output, and surviving sessions. Failed exits remain inspectable. Missing backends are not mistaken for successful exits.
- Existing shell processes survive frontend replacement. Tests exercise 17 simultaneous sessions and simulated backend loss with saved directory recovery.
- An opt-in live Codex test completed a real response using existing authentication, verified ANSI output and workspace/hook trust, then restarted the test backend and resumed the exact saved conversation. This was previously run successfully; ordinary test runs skip it to avoid unnecessary model requests.

## App and workspace behavior

GUI checks covered command-search focus, file search and syntax editing, a code-comment prompt in a new Codex terminal, native sidebar disclosure/selection, compact toolbars, content dividers without sidebar overlap, and persisted divider sizes. Hook-event fixtures verified the busy spinner, yellow approval indicator, and completed state; permission requests invoke the native sound once per event.

The layered leaf icon was opened and validated in Apple's Icon Composer, including default, dark, and monochrome variants. The packaged app includes compiled native icon assets and legacy icon renditions.

After a stale Dock icon appeared during in-place development, Freemind's registration was refreshed and the user confirmed the leaf was back. The packaging script now increments the build number to invalidate stale app artwork on subsequent builds.

The normal application registry now retains the workspaces opened during development, so launching the packaged app does not require a custom registry environment variable.

## Automated coverage and packaging

The regular suite covers atomic storage and recovery copies, relative paths, conflicting external edits, option quoting, hook metadata, pane grids, Git status/diffs, staging, commits, hooks, worktrees, first push, and rejected pushes that retain the local commit. Git tests use temporary repositories and local bare remotes.

Final regular run: 17 tests, 16 passed, one opt-in live Codex test skipped, zero failures (2026-09-05 00:56 local time).

Build with `bash Scripts/build-app.sh release`; output is `dist/Freemind.app`. The release build and `codesign --verify --deep --strict dist/Freemind.app` passed. The app is signed locally for development and is not notarized for distribution.

Detailed local logs are in `.build-support/test-final.log`, `live-codex-verification.txt`, `performance-ui.log`, `exit-ui-verification.json`, and `release-build.log`. They are excluded from Git.

A physical Mac reboot was not performed. Reboot recovery restores saved layout/output and Codex conversation identity using fresh processes; live shell memory and in-flight work cannot survive an OS reboot.

## Shareable zip (2026-09-06)

`bash Scripts/package-app.sh` produced `dist/Freemind-0.1.0-macOS-arm64.zip` (4.31 MB) and its SHA-256 checksum. The archive includes the app, an Applications shortcut, and first-launch instructions. It is for Apple Silicon Macs running macOS 14 or newer; it is locally signed and not notarized. Codex CLI and login remain separate.

The terminal backend and static libevent dependency were rebuilt with a macOS 14 deployment target in a separate build cache. Packaging now assembles a fresh app bundle and installs SwiftTerm's shader resources under the bundle name its renderer looks up.

The zip was extracted to a temporary directory with spaces in its path. Signature verification passed after extraction. All three executables are arm64, declare macOS 14.0, and dynamically link only macOS system libraries. Icons, shader sources, licenses, executable permissions, and the Applications shortcut were checked; no workspace state or credentials are included. The extracted app launched and initialized an empty test registry, and its bundled tmux/helper successfully ran a shell command. The temporary app and terminal processes were stopped afterward.

The regular suite passed again: 17 tests, 16 passed, one opt-in live Codex test skipped, zero failures. Runtime checks used macOS 26.6.2; macOS 14 and Intel hardware were not tested. Local logs are `.build-support/distribution-package.log`, `distribution-tests.log`, and `distribution-runtime.log`.

## Global settings and appearance (2026-09-06)

App settings now persist workspace defaults, app theme/mode, and independent terminal theme/mode. New workspace initialization copies global terminal options; reopening a workspace preserves its saved defaults and pane options. Settings tests cover persistence, compatible missing/unknown appearance values, invalid-option rejection, backup recovery, and inheritance without replacing existing workspace data.

The full suite passed with local terminal socket access: 22 tests, 21 passed, one opt-in live Codex test skipped, zero failures. Log: `.build-support/settings-tests-full.log`.

An isolated native rendering harness exercised Forest, Ocean, Violet, and Graphite in both modes, independent terminal appearance, and returning to System appearance. It verified that editor text/selection and terminal view identity/output survive live changes, and that editor and terminal palettes update independently. Offscreen Settings/editor renderings were inspected; this did not interact with the user's running app. Harness and artifacts: `.build-support/settings-qa/`.

A separate release preview was assembled at `dist/Settings Preview/Freemind.app` and passed deep/strict code-signature verification. It uses the existing compiled icon assets because sandboxed `actool` could not reach its platform services; app and helper executables were built from current source. Log: `.build-support/settings-preview-build.log`. The preview was not launched, and the running Freemind instance was not closed or restarted.

## Additional editor themes (2026-09-06)

Added VS Code, One Dark / Light, Dracula, GitHub, Nord, Solarized, Tokyo Night, and Catppuccin-inspired palettes to both appearance selectors, bringing the total to 12 themes. Each has light/dark app, syntax, and terminal ANSI colors. The Settings preview now includes ANSI color samples. Theme credits, adaptation notes, and upstream MIT notices are bundled in `Resources/licenses/Theme-inspirations.txt`.

The five settings tests passed. An isolated native harness checked all 24 palette variants, 16 valid ANSI entries per palette, persistence of every app/terminal theme, live native foreground/background changes, editor selection/text preservation, terminal identity/output preservation, and System-mode reset. Rendered Settings and editor samples were inspected. Logs and renderings: `.build-support/theme-settings-tests.log`, `.build-support/theme-qa/`.

Release build and deep/strict signature verification passed for `dist/Theme Preview/Freemind.app`; build log: `.build-support/theme-preview-build.log`. The separate preview was not launched. The running app and previous app bundles were not closed, restarted, or replaced.
