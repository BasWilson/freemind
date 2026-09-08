import Foundation
import FreemindCore
import LinuxUI

extension Controller {
    func handleWorkspace(_ action: String, value: String) async throws -> Bool {
        switch action {
        case "workspace-select": try await open(value)
        case "workspace-remove":
            if paths?.root.path == value { try await saveDocuments(); try saveRestoration(); try await checkpoint() }
            workspaces.removeAll { $0 == value }; try saveRegistry(removing: value)
            if paths?.root.path == value {
                if let next = workspaces.first { try await open(next) }
                else {
                    paths = nil; backend = nil; definition = nil; layout = .init(); restoration = .init()
                    codeDocument = .init(); notesDocument = .init()
                    await onUI { fm_workspace("No folder open", ""); fm_document("code", "", "", 0); fm_files_clear(); fm_notes_clear(); fm_watch_clear() }
                }
            }
            await refreshWorkspaces()
        case "next-workspace", "previous-workspace":
            guard !workspaces.isEmpty else { return true }
            let current = workspaces.firstIndex(of: paths?.root.path ?? "") ?? 0
            try await open(workspaces[(current + workspaces.count + (action == "next-workspace" ? 1 : -1)) % workspaces.count])
        case "workspace-up", "workspace-down":
            if let current = workspaces.firstIndex(of: value) {
                let target = min(workspaces.count - 1, max(0, current + (action == "workspace-up" ? -1 : 1)))
                workspaces.swapAt(current, target); try saveRegistry(); await refreshWorkspaces()
            }
        case "workspace-pin":
            let target = WorkspacePaths(root: URL(fileURLWithPath: value))
            var workspace = try DurableFile.load(WorkspaceDefinition.self, from: target.definition)
            workspace.pinned.toggle(); try DurableFile.save(workspace, to: target.definition)
            if target.root == paths?.root { definition = workspace; savedDefinition = try Data(contentsOf: target.definition) }
            await refreshWorkspaces()
        case "workspace-rename":
            renameWorkspaceTarget = value
            let current = try DurableFile.load(WorkspaceDefinition.self, from: WorkspacePaths(root: URL(fileURLWithPath: value)).definition)
            await onUI { fm_prompt("Rename workspace", "Changes the name shown in Freemind.", current.name, "workspace-renamed") }
        case "workspace-renamed":
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !renameWorkspaceTarget.isEmpty else { return true }
            let target = WorkspacePaths(root: URL(fileURLWithPath: renameWorkspaceTarget))
            var workspace = try DurableFile.load(WorkspaceDefinition.self, from: target.definition)
            workspace.name = name; try DurableFile.save(workspace, to: target.definition)
            if target.root == paths?.root { definition = workspace; savedDefinition = try Data(contentsOf: target.definition) }
            await refreshWorkspaces()
        case "workspace-window":
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            await onUI { fm_workspace_window(executable, value) }
        case "sidebar-width":
            sidebarWidth = max(170, min(600, Int(value) ?? 230)); try saveRegistry()
            let width = sidebarWidth, visible = sidebarVisible
            await onUI { fm_sidebar(Int32(width), visible ? 1 : 0) }
        case "sidebar-visible": sidebarVisible = value == "true"; try saveRegistry()
        case "window-size":
            let values = value.split(separator: "\n").compactMap { Double($0) }
            if values.count == 2 { restoration.window = .init(x: 0, y: 0, width: values[0], height: values[1]) }
        case "pane-window-size":
            let fields = value.split(separator: "\n")
            if fields.count == 3, let id = UUID(uuidString: String(fields[0])), restoration.detachedPanes[id] != nil, let width = Double(fields[1]), let height = Double(fields[2]) {
                restoration.detachedPanes[id] = .init(x: 0, y: 0, width: width, height: height)
            }
        case "view-state":
            let fields = value.split(separator: "\n", maxSplits: 1).map(String.init)
            guard fields.count == 2, let number = Double(fields[1]), number.isFinite else { return true }
            switch fields[0] {
            case "fileBrowserWidth": restoration.fileBrowserWidth = min(700, max(150, number))
            case "gitBrowserWidth": restoration.gitBrowserWidth = min(700, max(220, number))
            case "notesBrowserWidth": restoration.notesBrowserWidth = min(700, max(160, number))
            case "editorFraction": restoration.editorFraction = min(0.85, max(0.15, number))
            default: break
            }
        case "code", "git", "notes", "files":
            restoration.selectedTab = action == "files" ? "Code" : action.capitalized
            if action == "files" { restoration.filesVisible.toggle() }
            await showContent(); try saveRestoration()
            if action == "git" { try await refreshGit() }
            if action == "notes" { try await refreshNotes() }
        case "file-expand":
            if expandedFolders.contains(value) { expandedFolders.remove(value) } else { expandedFolders.insert(value) }
            try await refreshFiles()
        case "files-hidden": showHidden.toggle(); try await refreshFiles()
        case "files-refresh": try await refreshFiles()
        case "file-search": fileQuery = value; try await refreshFiles()
        case "file-open": try await openFile(value)
        case "file-close":
            try codeDocument.save(); restoration.selectedFile = nil; codeDocument = .init(draftURL: codeDocument.draftURL)
            await onUI { fm_document("code", "", "", 0) }; try saveRestoration()
        case "external", "reveal":
            let file = URL(fileURLWithPath: value)
            let uri = (action == "reveal" ? file.deletingLastPathComponent() : file).absoluteString
            await onUI { fm_open_uri(uri) }
        case "edit":
            guard let split = value.firstIndex(of: "\n") else { return true }
            let kind = String(value[..<split]), text = String(value[value.index(after: split)...])
            if kind == "notes" { try notesDocument.change(text); lastNoteEdit = Date() }
            else { try codeDocument.change(text) }
        case "cursor":
            let fields = value.split(separator: "\n", maxSplits: 1)
            guard fields.count == 2, let offset = Int(fields[1]) else { return true }
            if fields[0] == "notes" { notesDocument.cursor = offset; restoration.notePositions[restoration.selectedNote] = offset }
            else { codeDocument.cursor = offset; restoration.editorPosition = offset }
        case "save", "save-document":
            let kind = value.isEmpty ? (restoration.selectedTab == "Notes" ? "notes" : "code") : value
            if kind == "notes" { try notesDocument.save() } else { try codeDocument.save() }
            await onUI { fm_document_status(kind, "Saved in workspace", 0) }
        case "save-copy-to":
            let fields = value.split(separator: "\n", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return true }
            let document = fields[0] == "notes" ? notesDocument : codeDocument
            try document.saveCopy(to: URL(fileURLWithPath: fields[1]))
            await onUI { fm_document_status(fields[0], "Copy saved. Original edits are still available.", 1) }
        case "reload-document":
            let document = value == "notes" ? notesDocument : codeDocument
            if document.dirty { await onUI { fm_prompt("Reload disk version?", "Your unsaved edits in this document will be discarded. Save a copy first if you want to keep them.", "", "reload-confirmed-" + value) } }
            else { try await reloadDocument(value) }
        case "reload-confirmed-code": try await reloadDocument("code")
        case "reload-confirmed-notes": try await reloadDocument("notes")
        case "open-document-externally":
            if let url = (value == "notes" ? notesDocument : codeDocument).url { await onUI { fm_open_uri(url.absoluteString) } }
        case "disk-changed": diskDirty = true
        case "note-new": await onUI { fm_prompt("New note", "Give the Markdown note a name.", "", "note-create") }
        case "note-create":
            guard let paths else { return true }
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else { throw FreemindError.message("Choose a note name without a slash or newline.") }
            let filename = name.hasSuffix(".md") ? name : name + ".md"
            try Data(("# " + name + "\n\n").utf8).write(to: paths.notes.appendingPathComponent(filename), options: .withoutOverwriting)
            try notesDocument.save(); restoration.selectedNote = filename
            try await refreshNotes(); try saveRestoration()
        case "note-open":
            guard !value.contains("/"), value.hasSuffix(".md") else { return true }
            try notesDocument.save(); restoration.selectedNote = value
            try await refreshNotes(); try saveRestoration()
        case "notes-search": noteQuery = value; try await refreshNotes()
        case "notes-render": await renderNotes()
        case "palette", "quick-open", "comments": try await showPalette(action)
        case "quick-search": try await quickSearch(value)
        case "comment-selection":
            let fields = value.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let first = Int(fields[0]), let last = Int(fields[1]), codeDocument.url != nil else { return true }
            try codeDocument.save(); commentSelection = (first, last, fields[2])
            await onUI { fm_prompt("Ask Codex to change this code", "A new terminal will receive the file path, selected lines and your comment. The comment is saved in your workspace.", "", "comment-submit") }
        case "comment-submit": try await submitComment(value)
        case "comment-again":
            guard let paths, let id = UUID(uuidString: value), let comment = try DurableFile.load([CodeComment].self, from: paths.comments).first(where: { $0.id == id }) else { return true }
            _ = try await createPane(kind: .codex, title: "Review · " + URL(fileURLWithPath: comment.file).lastPathComponent, prompt: comment.prompt)
        case "pane-focus": restoration.focusedPane = UUID(uuidString: value)
        case "pane-rename":
            guard let pane = layout.panes.first(where: { $0.id.uuidString == value }) else { return true }
            renameTarget = value
            await onUI { fm_prompt("Rename terminal", "Choose a title for this terminal.", pane.title, "pane-renamed") }
        case "pane-renamed":
            guard let index = layout.panes.firstIndex(where: { $0.id.uuidString == renameTarget }) else { return true }
            let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return true }
            var updated = layout; updated.panes[index].title = title; try save(updated)
            let id = renameTarget; await onUI { fm_pane_title(id, title) }
        case "split-right", "split-below":
            if let id = UUID(uuidString: value) { restoration.focusedPane = id }
            _ = try await createPane(kind: .codex, split: action == "split-right" ? .horizontal : .vertical)
        case "pane-move":
            let ids = value.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
            guard ids.count == 2, let source = layout.panes.firstIndex(where: { $0.id == ids[0] }) else { return true }
            var updated = layout; let pane = updated.panes.remove(at: source)
            guard let target = updated.panes.firstIndex(where: { $0.id == ids[1] }) else { return true }
            updated.panes.insert(pane, at: target); updated.automatic = true
            if let first = updated.panes.first { updated.tree = updated.panes.dropFirst().reduce(LayoutNode.pane(first.id)) { .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: $0, second: .pane($1.id)) } }
            try save(updated); await onUI { fm_move_pane(ids[0].uuidString, Int32(target)) }; await renderPaneLayout()
        case "pane-ratio":
            let fields = value.split(separator: "\n", maxSplits: 1)
            guard fields.count == 2, let id = UUID(uuidString: String(fields[0])), let ratio = Double(fields[1]), ratio.isFinite else { return true }
            var updated = layout; updated.tree = updated.tree?.settingRatio(id, ratio); try save(updated)
            await onUI { fm_pane_ratio(id.uuidString, min(0.85, max(0.15, ratio))) }
        case "pane-maximize", "maximize":
            let id = UUID(uuidString: value); restoration.maximizedPane = restoration.maximizedPane == id ? nil : id
            let target = restoration.maximizedPane?.uuidString ?? ""; await onUI { fm_pane_maximize(target) }; try saveRestoration()
        case "arrange":
            var updated = layout; updated.automatic = true; try save(updated); restoration.maximizedPane = nil
            await onUI { fm_pane_maximize("") }; await renderPaneLayout(); try saveRestoration()
        case "pane-detach":
            guard let id = UUID(uuidString: value) else { return true }
            if restoration.detachedPanes[id] != nil { restoration.detachedPanes[id] = nil }
            else { restoration.detachedPanes[id] = .init(x: 0, y: 0, width: 1000, height: 700) }
            await onUI { fm_pane_detach(value) }; try saveRestoration()
        case "pane-reattached":
            if let id = UUID(uuidString: value) { restoration.detachedPanes[id] = nil; try saveRestoration() }
        case "pane-history", "pane-export": try await history(value, export: action == "pane-export")
        case "close-focused":
            guard let id = UUID(uuidString: value) else { return true }
            renameTarget = id.uuidString
            await onUI { fm_prompt("Stop and close terminal?", "The process in this terminal will stop. Saved output remains in your workspace.", "", "close-confirmed") }
        case "close-confirmed": if let id = UUID(uuidString: renameTarget) { try await close(id) }
        case "zoom-in", "zoom-out", "zoom-reset":
            guard let id = UUID(uuidString: value), let paths else { return true }
            let url = paths.terminal(id).appendingPathComponent("font.json")
            let current = (try? DurableFile.load(Double.self, from: url)) ?? 11
            let next = action == "zoom-reset" ? 11 : min(28, max(9, current + (action == "zoom-in" ? 1 : -1)))
            try DurableFile.save(next, to: url); await onUI { fm_pane_font(value, next) }
        case "configure":
            defaultsDraft = definition?.defaults ?? settings.workspaceDefaults; paneKind = .codex; paneTitle = ""; paneSaveDefaults = false
            defaultsScope = "new"; try await showSettings(page: "defaults")
        case "pane-create":
            _ = try defaultsDraft.arguments()
            if paneSaveDefaults { try saveWorkspaceDefaults(defaultsDraft) }
            _ = try await createPane(kind: paneKind, title: paneTitle, options: defaultsDraft)
            await onUI { fm_settings_message("Terminal created.", 0) }
        case "cli-help":
            let executable = try TerminalBackend.resolveCodex(defaultsDraft.executable, environment: environment)
            let result = try await CommandRunner.run(executable, ["--help"], environment: environment).checked()
            await onUI { fm_text_window("Installed CLI options", result.output) }
        case "quit-stop":
            await onUI { fm_prompt("Quit and stop all terminals?", "Every terminal in the open workspaces will stop. Normal Quit keeps them running.", "", "quit-stop-confirmed") }
        case "quit-stop-confirmed":
            try await saveDocuments(); try saveRestoration(); try await checkpointAll(stop: true)
            try await updater.installOnQuit(); shuttingDown = true; await onUI { fm_quit() }
        default:
            if action.hasPrefix("git-") || action == "commit-draft" { return try await handleGit(action, value: value) }
            return false
        }
        return true
    }

    func saveRegistry(removing: String? = nil) throws {
        let disk = try? DurableFile.load(LinuxState.self, from: stateURL)
        var merged = workspaces
        for path in disk?.workspaces ?? [] where path != removing && !merged.contains(path) { merged.append(path) }
        workspaces = merged
        let last = paths?.root.path == removing ? merged.first ?? "" : paths?.root.path ?? merged.first ?? ""
        try DurableFile.save(LinuxState(lastWorkspace: last, workspaces: merged, sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible), to: stateURL)
    }
    func refreshWorkspaces() async {
        let selected = paths?.root.path
        let rows = workspaces.map { path -> (String, String, Bool, Bool) in
            let workspace = WorkspacePaths(root: URL(fileURLWithPath: path))
            let definition = try? DurableFile.load(WorkspaceDefinition.self, from: workspace.definition)
            return (path, definition?.name ?? URL(fileURLWithPath: path).lastPathComponent, definition?.pinned ?? false, FileManager.default.fileExists(atPath: path))
        }.sorted { $0.2 && !$1.2 }
        await onUI {
            fm_workspace_list_clear()
            for row in rows { fm_workspace_list_add(row.0, row.1, row.0 == selected ? 1 : 0, row.2 ? 1 : 0, row.3 ? 1 : 0) }
        }
    }
    func saveRestoration() throws {
        guard let paths else { return }
        restoration.editorPosition = codeDocument.cursor
        restoration.notePositions[restoration.selectedNote] = notesDocument.cursor
        try DurableFile.save(restoration, to: paths.restoration); lastRestorationSave = Date()
    }
    func showContent() async {
        let view = restoration
        await onUI { fm_content_show(view.selectedTab, view.filesVisible ? 1 : 0, boundedPixels(view.fileBrowserWidth, fallback: 230, minimum: 150), boundedPixels(view.gitBrowserWidth, fallback: 300, minimum: 220), boundedPixels(view.notesBrowserWidth, fallback: 220, minimum: 160), view.editorFraction ?? 0.5) }
    }
    func saveDocuments() async throws { try codeDocument.save(); try notesDocument.save() }
    func openFile(_ relative: String) async throws {
        guard let paths else { return }
        let file = paths.resolve(relative)
        codeDocument.cursor = restoration.editorPosition
        try codeDocument.load(file)
        restoration.selectedFile = paths.relative(file); restoration.selectedTab = "Code"; restoration.filesVisible = true
        let document = codeDocument
        await onUI { fm_document("code", paths.relative(file), document.text, Int32(document.cursor)); fm_watch(file.path); fm_watch(file.deletingLastPathComponent().path); fm_document_status("code", "", document.dirty ? 1 : 0) }
        await showContent(); try await refreshFiles(); try saveRestoration()
    }
    func reloadDocument(_ kind: String) async throws {
        if kind == "notes", let url = notesDocument.url { try notesDocument.load(url, force: true) }
        else if let url = codeDocument.url { try codeDocument.load(url, force: true) }
        let document = kind == "notes" ? notesDocument : codeDocument
        await onUI { fm_document(kind, document.url?.lastPathComponent ?? "", document.text, Int32(document.cursor)); fm_document_status(kind, "Reloaded from disk", 0) }
    }
    func refreshFiles() async throws {
        guard let paths else { return }
        var rows: [(String, String, Int, Bool, Bool, Bool)] = []
        var watched: [String] = [paths.root.path]
        if !fileQuery.isEmpty {
            rows = WorkspaceFileListing.search(paths.root, query: fileQuery, hidden: showHidden).map { ($0.url.path, paths.relative($0.url), 0, false, false, paths.relative($0.url) == restoration.selectedFile) }
        } else {
            func visit(_ folder: URL, depth: Int) throws {
                guard depth < 40, rows.count < 2000 else { return }
                for entry in try WorkspaceFileListing.children(folder, hidden: showHidden) {
                    let expanded = expandedFolders.contains(entry.url.path)
                    rows.append((entry.url.path, entry.url.lastPathComponent, depth, entry.directory, expanded, paths.relative(entry.url) == restoration.selectedFile))
                    if entry.directory && expanded { watched.append(entry.url.path); try visit(entry.url, depth: depth + 1) }
                }
            }
            try visit(paths.root, depth: 0)
        }
        await onUI {
            fm_files_clear()
            for row in rows { fm_file_row(row.0, row.1, Int32(row.2), row.3 ? 1 : 0, row.4 ? 1 : 0, row.5 ? 1 : 0) }
            for folder in watched { fm_watch(folder) }
        }
    }
    func refreshNotes() async throws {
        guard let paths else { return }
        let files = try FileManager.default.contentsOfDirectory(at: paths.notes, includingPropertiesForKeys: [.isRegularFileKey]).filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let filtered = files.filter { noteQuery.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(noteQuery) || ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").localizedCaseInsensitiveContains(noteQuery) }
        let selected = restoration.selectedNote
        let file = paths.notes.appendingPathComponent(selected)
        let changed = notesDocument.url != file
        notesDocument.cursor = restoration.notePositions[selected] ?? 0
        try notesDocument.load(file)
        let document = notesDocument
        await onUI {
            fm_notes_clear(); for file in filtered { fm_note_row(file.lastPathComponent, file.lastPathComponent == selected ? 1 : 0) }
            if changed { fm_document("notes", selected, document.text, Int32(document.cursor)) }
            fm_watch(paths.notes.path); fm_watch(file.path)
        }
        await renderNotes()
    }
    func renderNotes() async {
        let markup = MarkdownMarkup.render(notesDocument.text)
        await onUI { fm_note_preview(markup) }
    }
    func pollWorkspace() async throws {
        if notesDocument.dirty && Date().timeIntervalSince(lastNoteEdit) > 0.35 {
            lastNoteEdit = .distantFuture
            do { try notesDocument.save(); await onUI { fm_document_status("notes", "Saved in workspace", 0) }; await renderNotes() }
            catch { await onUI { fm_document_status("notes", error.localizedDescription, 1) } }
        }
        if diskDirty || Date().timeIntervalSince(lastDiskCheck) >= 3 {
            let refreshTree = diskDirty
            diskDirty = false; lastDiskCheck = Date()
            for kind in ["code", "notes"] {
                do {
                    let changed = try kind == "code" ? codeDocument.externalChange() : notesDocument.externalChange()
                    if changed {
                        let doc = kind == "code" ? codeDocument : notesDocument
                        await onUI { fm_document(kind, doc.url?.lastPathComponent ?? "", doc.text, Int32(doc.cursor)); fm_document_status(kind, "Reloaded external changes", 0) }
                    }
                } catch { await onUI { fm_document_status(kind, error.localizedDescription, 1) } }
            }
            if refreshTree { try await refreshFiles() }
            // Other windows may change appearance; use their last valid save.
            if let data = try? Data(contentsOf: settingsURL), data != savedSettings {
                settings = try AppSettings.load(from: settingsURL); savedSettings = data; await applyAppearance()
            }
        }
        if paths != nil && Date().timeIntervalSince(lastRestorationSave) >= 3 { try saveRestoration() }
        if !gitWorking, Date().timeIntervalSince(lastGitCheck) >= 3 {
            if restoration.selectedTab == "Git" { try await refreshGit() }
            else if let service = gitService {
                lastGitCheck = Date()
                let root = paths?.root
                let branch = (try? await service.currentBranch()) ?? ""
                if paths?.root == root, gitService === service { await onUI { fm_branch(branch) } }
            }
        }
    }
    @discardableResult func createPane(kind: PaneKind, title: String = "", options: CodexOptions? = nil, split: SplitAxis? = nil, prompt: String? = nil) async throws -> PaneDefinition {
        guard let backend else { throw FreemindError.message("Open a workspace first.") }
        let pane = PaneDefinition(title: title.isEmpty ? (kind == .shell ? "Shell" : "Codex") : title, kind: kind, options: options ?? definition?.defaults ?? settings.workspaceDefaults)
        var updated = layout; updated.panes.append(pane)
        if let tree = updated.tree {
            if let split { updated.tree = tree.splitting(restoration.focusedPane ?? tree.paneIDs.last ?? pane.id, with: pane.id, axis: split); updated.automatic = false }
            else { updated.tree = .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: tree, second: .pane(pane.id)) }
        } else { updated.tree = .pane(pane.id) }
        try save(updated); restoration.selectedTab = "Code"; restoration.focusedPane = pane.id; restoration.maximizedPane = nil
        if let prompt { try await backend.start(pane, initialPrompt: prompt) }
        try await attach(pane); await renderPaneLayout(); await showContent(); try saveRestoration()
        return pane
    }
    func renderPaneLayout() async {
        func encode(_ tree: LayoutNode) -> String {
            switch tree {
            case .pane(let id): return "P " + id.uuidString
            case .split(let id, let axis, let ratio, let first, let second): return "S \(id.uuidString) \(axis == .horizontal ? "h" : "v") \(ratio)\n" + encode(first) + "\n" + encode(second)
            }
        }
        let spec = layout.automatic ? "" : layout.tree.map(encode) ?? ""
        await onUI { fm_pane_layout(spec) }
    }
    func saveWorkspaceDefaults(_ options: CodexOptions) throws {
        guard let paths, var updated = definition else { return }
        guard (try? Data(contentsOf: paths.definition)) == savedDefinition else { throw FreemindError.message("Workspace settings changed on disk. Reopen the workspace first.") }
        _ = try options.arguments(); updated.defaults = options
        try DurableFile.save(updated, to: paths.definition); definition = updated; savedDefinition = try Data(contentsOf: paths.definition)
    }
    func checkpointAll(stop: Bool = false) async throws {
        try await checkpoint()
        for path in workspaces {
            let target = WorkspacePaths(root: URL(fileURLWithPath: path))
            guard let saved = try? DurableFile.load(WorkspaceLayout.self, from: target.layout) else { continue }
            let tmux = try executable("tmux", override: environment["FREEMIND_TMUX"])
            let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("freemind-helper").path
            let backend = TerminalBackend(paths: target, executable: tmux, helper: helper, environment: environment)
            let snapshots = await backend.snapshot()
            for pane in saved.panes {
                _ = try await backend.checkpoint(pane, running: snapshots.first { $0.paneID == pane.id })
                if stop, await backend.exists(pane.id) { try await backend.stop(pane.id) }
            }
        }
    }
    func history(_ value: String, export: Bool) async throws {
        guard let id = UUID(uuidString: value), let paths, let backend, let pane = layout.panes.first(where: { $0.id == id }) else { return }
        let output = (try? await backend.capture(id)) ?? (try? String(contentsOf: paths.terminal(id).appendingPathComponent("screen.ansi"), encoding: .utf8)) ?? "No saved output yet."
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        if export {
            let file = paths.metadata.appendingPathComponent("history/\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).md")
            try Data(("# \(pane.title)\n\n```text\n" + clean + "\n```\n").utf8).write(to: file, options: .atomic)
            try await openFile(file.path)
        } else { await onUI { fm_text_window("Saved output · " + pane.title, clean) } }
    }
    func submitComment(_ text: String) async throws {
        guard let paths, let (first, last, selection) = commentSelection, let file = codeDocument.url else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        let before = try? Data(contentsOf: paths.comments)
        var comments = before == nil ? [] : try DurableFile.load([CodeComment].self, from: paths.comments)
        var comment = CodeComment(file: paths.relative(file), startLine: first, endLine: last, selection: selection, comment: text)
        let pane = try await createPane(kind: .codex, title: "Review · " + file.lastPathComponent, prompt: comment.prompt)
        comment.paneID = pane.id
        guard (try? Data(contentsOf: paths.comments)) == before else { throw FreemindError.message("Comments changed on disk. The review terminal was started, but the comment could not be saved.") }
        comments.append(comment); try DurableFile.save(comments, to: paths.comments)
    }
}

private enum MarkdownMarkup {
    static func escaped(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
    static func render(_ text: String) -> String {
        var code = false
        return text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("```") { code.toggle(); return "" }
            let safe = escaped(line)
            if code { return "<tt>" + safe + "</tt>" }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                return "<span size=\"\(hashes == 1 ? "xx-large" : hashes == 2 ? "x-large" : "large")\" weight=\"bold\">" + escaped(String(line.dropFirst(hashes + 1))) + "</span>"
            }
            var result = safe.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
            result = result.replacingOccurrences(of: "`([^`]+)`", with: "<tt>$1</tt>", options: .regularExpression)
            result = result.replacingOccurrences(of: "\\*([^*]+)\\*", with: "<i>$1</i>", options: .regularExpression)
            if result.hasPrefix("- ") || result.hasPrefix("* ") { result = "• " + result.dropFirst(2) }
            return result
        }.joined(separator: "\n")
    }
}
