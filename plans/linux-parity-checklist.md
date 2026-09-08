# Linux / Mac workflow coverage

Updated 2026-09-08. This maps the Mac frontend's workflows to the Linux port.
“Implemented” means the controls and behavior are connected; the validation
column records the narrower behavior actually exercised. It does not imply every
interaction has been manually tested on every compositor or architecture.

| Mac workflow | Linux implementation | Validation |
| --- | --- | --- |
| Open, retain and switch workspaces | Persistent XDG registry and sidebar; existing tmux sessions remain alive | Native test opens two folders, switches back, relaunches and checks original shell PIDs |
| Workspace rename, pin, reorder, remove, separate window | Sidebar menus and independent native windows | Implemented; full manual menu matrix pending |
| Resizable sidebars, browser columns, editor area | GtkPaned handles and workspace/global restoration | Native test checks saved sidebar and split preferences; visually checked in Hyprland |
| File tree, hidden files, search, quick open, external opening, drag | Monitored hierarchy and searchable command/file dialog | Core tree/symlink tests and native file-opening test; drag and external apps require manual checks |
| Source editor, syntax, line numbers, undo, find, save | GtkSourceView with shared palette | Native edit/save; five core tests cover drafts, conflicts, file limits and tree/palette behavior |
| Crash drafts, external edits, reload, save copy | Shared WorkspaceDocument with optimistic comparison | Restored draft/conflict tests; native test preserves an external edit and saves a copy |
| Code selection comments, review terminal, saved comments | Shared CodeComment format and helper launch | Implemented; live authenticated review submission not run |
| Notes, new note, search, autosave, Markdown preview | Native notes browser/editor and formatted preview | Native create/edit/autosave and preview checks |
| Git status, unified/split diffs, stage/unstage | Shared GitService and native changes panels | Core Git tests and native stage/diff operations |
| Git commit, branches, fetch, push, publish branch | Shared service, existing Git credentials/hooks, explicit UI actions | Native commit and branch switch; core Git tests; real remote credentials not exercised |
| New Codex/shell, configured launch, workspace/global defaults, CLI help | All shared CodexOptions fields and settings scopes | Native global defaults seed a second workspace; core argument/defaults tests |
| Reorder, split right/below, resize, maximize, detach, font size | Persistent shared tree, GtkPaned splits, retained VTE widgets | Native reorder, manual ratio and detaching checks retain processes/clients |
| Resume/reconnect, history, success/failure status, approval indicators | Shared tmux/helper/recovery and scoped hook events | Core persistence/recovery/hooks/concurrency tests; live authenticated Codex resume remains opt-in |
| Quit preserves sessions; explicit close stops a pane | Checkpoints plus separate tmux server lifecycle | Native quit/relaunch retains shell PIDs, environment and unsent input; explicit close tested |
| App/terminal mode and themes; opacity | Shared 12 palettes, portal appearance, independent VTE colors | Native settings persist and theme changes preserve VTE clients; visual inspection |
| Custom themes, light/dark/ANSI editing, configuration, Codex designer | Shared themes.json validation, editor and theme-workspace launch | Shared theme tests; live Codex theme generation not submitted |
| Commands and shortcuts | Searchable native palette and Linux key bindings | Implemented; full manual keyboard/Hyprland binding matrix pending |
| Automatic updates and first install | Signed per-user archives, daily checks, optional download, install on quit; one-command GitHub installer and release instructions | 19 signature/tamper/installer/signing-setup tests plus real-binary piped installer, repeat install and desktop launcher smoke pass |
| Window restoration | Workspace view state, pane layout, fonts, sidebar widths, detached terminals | Native relaunch checks; Wayland controls absolute window placement |

Remaining release validation: production signing configuration and first Linux
release, clean x86_64/ARM64 installs, macOS CI, real authenticated Codex workflows,
full terminal input/clipboard/mouse/color/scaling matrix, and compositor window
behavior. No release was published by this implementation task. Arch package
manager distribution remains separate from the working per-user updater.
