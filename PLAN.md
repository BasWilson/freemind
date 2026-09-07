# Freemind implementation plan

Status: implementation in progress, 4 September 2026. Includes the subsequent requests for configurable CLI options, activity hooks, and code comments that launch Codex panes.

Build a native macOS app in SwiftUI around the user's existing Codex CLI. A workspace corresponds to a folder on disk. Its terminal panes, layouts, notes, and recovery data belong to that folder. Use the supplied screenshot as a visual reference for the sidebar and terminal cards; text appearing inside the screenshot is not an instruction.

1. **Product and interaction design**

   The main window has a resizable workspace sidebar and three top tabs: **Code | Git | Notes**. Use a compact dark appearance, thin borders, readable monospace terminal text, and a clear focus indicator. There is no Freemind account, hosted backend, Agents tab, or Chat tab. Codex retains its own authentication and model connectivity requirements.

   Add an existing folder with the macOS folder picker. Workspaces can be named, pinned, reordered, and reopened. Adding a folder does not copy it or create a Git worktree. Removing its sidebar entry leaves its files intact.

   Code contains independently running terminal panes. New panes start Codex in the selected workspace; a regular shell is also available. Each pane has a title, running/exited indicator, add, split, maximize, and close controls. Titles are editable. Keyboard shortcuts cover adding a pane, changing focus, splitting, and maximizing.

   Provide workspace-wide Codex defaults and per-pane launch options for model, profile, reasoning effort, permissions, web search, inline display, local providers, additional directories, config overrides, and additional CLI arguments. Query the installed CLI's help directly. Preserve these settings for recovery.

   Provide a workspace file explorer, syntax-highlighted native text editor with line numbers, and code-range comments. A comment records the file, line range, selected code, and requested change; starting it creates a new Codex pane with that context as its initial prompt. Store comments in `.freemind/comments.json` and never resubmit an initial prompt when restoring a pane.

   Use locally generated Codex hooks for session association and activity indicators, including working, needs approval, and done. Hooks only observe bounded event metadata and never approve actions or alter prompts. Trust only the generated hook definitions.

   Support horizontal and vertical splits, draggable dividers, pane reordering, and an Auto Arrange command. An adaptive grid distributes available space when using automatic arrangement; a persisted split tree retains custom proportions. There is no application-imposed pane count. When too many panes would become unreadable, preserve minimum usable sizes and allow scrolling or maximizing a pane. Resize the underlying terminal together with its view.

   Support additional native windows for separate workspaces and detaching a pane into its own window. A detached pane keeps its identity and running process. Record window placement and pane ownership. Restore windows onto a visible display if the monitor arrangement changes.

2. **Native architecture**

   Use SwiftUI for navigation, workspace controls, layout, and Git/Notes surfaces. Use AppKit interoperability for terminal views, precise focus, window restoration, and native text editing where useful. Target macOS 14 or later initially, with validation on the user's current Apple Silicon Mac.

   Embed SwiftTerm through `NSViewRepresentable`. SwiftTerm supplies an AppKit terminal view, ANSI/VT emulation, and local pseudo-terminal integration. Pin a tested package revision. The first prototype must verify Codex rendering, input, scrolling, and resizing rather than assuming complete compatibility. [SwiftTerm documentation](https://github.com/migueldeicaza/SwiftTerm)

   Bundle a pinned tmux executable and its required libraries in the app bundle. Maintain an app-owned server and a stable session identifier for each terminal pane, separate from the user's tmux configuration. The terminal view attaches as a client. tmux supports detaching clients while sessions continue and attaching again later. Hide its normal status bar and bindings so the app owns the visible pane controls. [tmux manual](https://man.openbsd.org/tmux.1)

   Keep session ownership outside SwiftUI view lifetime. Switching tabs, changing workspaces, or rearranging panes must never recreate their processes. Use services for workspace storage, terminal sessions, Codex recovery, Git inspection, and filesystem observation, with asynchronous work away from the main thread.

   Detect the installed Codex executable using the user's login-shell environment and allow an explicit path. Launch processes with structured executable/argument/environment values. Ship a directly runnable `.app`; the app's distribution sandbox is separate from Codex's own permission settings.

3. **Folder-owned data and Git portability**

   Proposed structure inside every selected project folder:

   ```text
   project/
     .freemind/
       workspace.json           # versioned workspace identity and settings
       layout.json              # pane definitions, layout, and proportions
       notes/
         Notes.md               # ordinary Markdown files
       history/                 # optional, explicitly exported history
       local/                   # ignored by Git by default
         restoration.json       # last UI state and live-session mapping
         terminals/             # scrollback and screen checkpoints
         codex/                 # workspace/pane-specific Codex state
       .gitignore
   ```

   Store paths relative to the workspace whenever possible. Version JSON schemas, write files atomically, debounce frequent changes, and retain a last-known-good recovery copy. Watch for external edits and Git operations; avoid overwriting a changed note or layout without detecting it.

   All app-managed workspace content stays beneath `.freemind`. Track configuration, layout, and notes normally. Keep mutable runtime databases, machine-specific recovery state, and raw terminal output in `local/`, ignored by default. Allow deliberate history export for versioning. Git can carry the workspace setup and notes to another Mac; it cannot carry a live process.

   Use an isolated Codex state directory beneath the workspace, potentially one per pane to make recovery association unambiguous. Codex documents a configurable state root that includes sessions, logs, configuration, and authentication. Isolating SQLite state alone is insufficient. [Codex state locations](https://learn.chatgpt.com/docs/config-file/environment-variables)

   Existing Codex login reuse and refresh across isolated state roots must be proved in the first milestone. Credentials belong in the existing machine credential store or protected, ignored storage, never in versioned JSON or exported history. Do not assume that switching the Codex state root automatically shares authentication. Codex supports file and OS credential storage. [Codex authentication](https://learn.chatgpt.com/docs/auth)

   Two small machine-level exceptions are necessary: a registry of folder bookmarks and open-window references to find the workspaces on launch, and OS credential storage. OS-managed temporary sockets may also require a short external path because Unix socket paths have length limits. These are references, credentials, or transient endpoints; workspace documents and recovery checkpoints remain inside the selected folder. Shells and arbitrary programs may still use their normal user-level configuration and storage.

4. **Restoration contract**

   | Event | Expected behavior |
   | --- | --- |
   | Switch workspace/tab or rearrange panes | Keep each existing process alive and reconnect its view. |
   | Close a window or quit Freemind | Save view state and detach clients; terminals continue in the background. |
   | Reopen Freemind | Restore workspaces, windows, active tab/pane, layouts, and scroll positions; reattach to the same live sessions. |
   | Freemind crashes | Recover the most recent saved UI state and reattach if the tmux server survived. |
   | Mac reboots, user logs out, or terminal backend dies | Restore saved layout/output, start fresh terminal processes, and reopen each saved Codex conversation. |

   Exact live-process continuity is achievable across an app restart while its background sessions survive. It is not achievable across a Mac reboot. Periodic checkpoints support recovery but may lose the last unflushed output after abrupt failure.

   Save a specific Codex conversation ID for each pane. Use `codex resume <session-id>` when the process is gone; never select the workspace's most recent conversation for every pane. Codex supports interactive resume by ID. A resumed conversation is not restoration of shell memory, running commands, network connections, or an unfinished request. [Codex resume reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli#codex-resume)

   Verify a reliable pane-to-conversation association, including `/new`, resume, and fork, during the first milestone. Prefer supported session events where available; otherwise use isolated per-pane session storage and a versioned compatibility adapter. Persist the ID promptly rather than waiting for a normal quit.

   Track terminal scrollback through the backend and save readable output checkpoints. Codex's inline display mode is a candidate for more predictable history; choose it only after visual testing. Restored historical output must be distinguishable from new process output. Unsubmitted input inside a live process survives reattachment; recovery after process loss cannot promise arbitrary TUI input restoration.

   Pane removal explicitly ends that pane's session. Provide a separate Quit and Stop Terminals action for intentionally ending all app-owned sessions. After a reboot, reopen Codex conversations without submitting a prompt and restore ordinary shells at their saved directories; do not automatically replay arbitrary commands.

5. **Git tab: review, commit, and push**

   Show the selected workspace's repository, branch, changed-file count, and additions/deletions. Group staged, unstaged, and untracked files. Selecting a file opens a unified diff with line numbers and colored additions/deletions; offer a side-by-side view once the core renderer is working.

   Handle added, modified, renamed, deleted, conflicted, binary, and untracked files deliberately. A file changed in both index and working tree appears in both relevant groups. Paginate or truncate very large previews with an explicit indicator. For a folder without Git, show a useful empty state.

   Allow staging and unstaging individual files or all changes. Include a commit-message editor, a summary of staged changes, and Commit, Push, and Commit & Push actions. Commit the staged changes, preserve the message draft when a commit fails, and respect the repository's existing identity, hooks, and signing configuration. If a push fails after a successful commit, retain that commit and offer retrying the push.

   Show the current branch, remote/upstream destination, and ahead/behind counts based on the latest fetched state. On the first push of a branch without an upstream, let the user choose its remote and destination branch and establish tracking. Use existing Git SSH/HTTPS authentication. Display operation progress and actionable errors for authentication problems, hook/signing failures, conflicts, and rejected pushes. Keep the UI responsive, serialize Git mutations per repository, and refresh status after each operation.

   Query the installed Git CLI asynchronously. Use machine-readable status output with NUL-delimited paths, and disable external diff/text conversion when generating previews. Debounce filesystem changes, cancel outdated work, and refresh when the app regains focus. Respect repository/worktree roots; clearly label the scope when the selected folder is a subdirectory and make the affected repository and branch visible beside commit/push controls.

6. **Notes tab**

   Provide a Markdown note list, native editor, preview, search, and autosave. Keep the files directly editable in other tools and suitable for Git. Retain the selected note and cursor/scroll position. Detect external changes and preserve both versions on a conflicting edit.

7. **Build order and completion checks**

   | Milestone | Deliverable | Completion check |
   | --- | --- | --- |
   | 1. Terminal and recovery prototype | One SwiftUI window, a real Codex terminal, persistent backend, folder-local state. | Quit/relaunch and force-quit retain the same session; isolated Codex storage and existing login reuse are verified; a killed session resumes the correct conversation. |
   | 2. Workspaces and layout | Sidebar, folder picker, unlimited pane model, auto arrangement, custom splits, multiple windows. | Multiple workspaces retain distinct panes; repeated resize and tab switches do not restart processes; all layout/window state restores. |
   | 3. Git workflow | Changed-file browser, diff renderer, staging, commit editor, and push controls. | Temporary repositories and local bare remotes cover staged/unstaged overlap, untracked files, rename/delete, conflicts, worktrees, unusual paths, binary and large files, staging/unstaging, commits, hook failures, first push/upstream setup, successful pushes, and rejected pushes that preserve local commits. |
   | 4. Notes and portable storage | Markdown editing, autosave, schema migration, external-change handling. | Move/reopen a folder, reopen notes, simulate interrupted saves, and check that a normal Git add excludes runtime/credential data. |
   | 5. Recovery and packaging | Complete session recovery, shortcuts, native polish, bundled dependencies, `.app` and build instructions. | Exercise 1/4/9/16+ panes, sustained output, Unicode, paste and interrupts, app restart, simulated backend loss, missing folders, and changed displays. A real reboot test is performed by the user, not triggered automatically. |

   The first milestone is the feasibility gate for terminal fidelity, persistence, and authentication. Resolve failures there before expanding the UI. Use unit tests for durable state, recovery identity, and Git parsing, plus focused integration and manual GUI checks. Measure resize responsiveness and output handling with many panes; avoid treating a successful build as proof of terminal correctness.

   Planning baseline: the repository was empty, Swift 6.3.3 and Codex CLI 0.152.1 were detected, and tmux was not on PATH. Implementation is now packaged in `dist/Freemind.app`; completed checks and practical limits are recorded in [VERIFICATION.md](VERIFICATION.md).
