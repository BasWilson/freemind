import AppKit
import SwiftUI
import FreemindCore
import CoreServices

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    var onChange: () -> Void
    let ignored: String
    let hooksOnly: Bool
    init(root: URL, hooksOnly: Bool = false, onChange: @escaping () -> Void) {
        self.hooksOnly = hooksOnly
        self.onChange = onChange; self.ignored = root.appendingPathComponent(".freemind/local").path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let owner = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if changed.contains(where: { owner.hooksOnly ? ($0.hasSuffix("/event.json") || $0.hasSuffix("/session.json") || $0.hasSuffix("/exit-event.json")) : (!$0.hasPrefix(owner.ignored + "/") && $0 != owner.ignored) }) { owner.onChange() }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), hooksOnly ? 0.15 : 0.5,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}

@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
    let paths: WorkspacePaths
    @Published var definition: WorkspaceDefinition
    @Published var layout: WorkspaceLayout
    @Published var restoration: Restoration
    @Published var comments: [CodeComment]
    @Published var error: String?
    @Published var externalRevision = 0
    @Published var sessions: [UUID: TerminalSession] = [:]
    let backend: TerminalBackend
    let git: GitModel
    let codeDocument = EditorDocument()
    let notesDocument = EditorDocument()
    nonisolated let id: UUID
    private var saveTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var watcher: FolderWatcher?
    private var hookWatcher: FolderWatcher?
    private var savedDefinition: Data?, savedLayout: Data?, savedComments: Data?
    private var initialized = false
    private var pendingSave = false
    private var closingPanes: Set<UUID> = []

    init(root: URL, environment: [String: String], defaults: CodexOptions = .init()) throws {
        paths = WorkspacePaths(root: root); try paths.initialize(defaults: defaults)
        let loadedDefinition = try DurableFile.load(WorkspaceDefinition.self, from: paths.definition)
        definition = loadedDefinition; id = loadedDefinition.id
        let loadedLayout = try DurableFile.load(WorkspaceLayout.self, from: paths.layout)
        guard loadedLayout.schemaVersion == 1 else { throw FreemindError.message("Unsupported layout format.") }
        layout = loadedLayout
        restoration = (try? DurableFile.load(Restoration.self, from: paths.restoration)) ?? .init()
        comments = (try? DurableFile.load([CodeComment].self, from: paths.comments)) ?? []
        savedDefinition = try? Data(contentsOf: paths.definition); savedLayout = try? Data(contentsOf: paths.layout)
        backend = TerminalBackend(paths: paths, executable: AppPaths.tmux, helper: AppPaths.helper, environment: environment)
        git = GitModel(folder: paths.root, environment: environment)
        savedComments = try? Data(contentsOf: paths.comments)
        codeDocument.draftURL = paths.local.appendingPathComponent("editors/code.json")
        notesDocument.draftURL = paths.local.appendingPathComponent("editors/notes.json")
        watcher = FolderWatcher(root: paths.root) { [weak self] in self?.diskChanged() }
        let events = paths.local.appendingPathComponent("terminals")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        hookWatcher = FolderWatcher(root: events, hooksOnly: true) { [weak self] in
            self?.refreshHookStatus()
            Task { [weak self] in await self?.refreshExitedPanes() }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.checkpoint()
            }
        }
    }
    deinit { monitor?.cancel(); saveTask?.cancel() }
    func activate() {
        guard !initialized else { return }; initialized = true
        for pane in layout.panes { ensureSession(pane) }
        Task { await git.refresh() }
    }
    func ensureSession(_ pane: PaneDefinition, prompt: String? = nil, focusWhenReady: Bool = false) {
        guard sessions[pane.id] == nil else { return }
        let session = TerminalSession(pane: pane, backend: backend, paths: paths)
        session.onFocus = { [weak self] in guard let self, self.restoration.focusedPane != pane.id else { return }; self.restoration.focusedPane = pane.id; self.saveSoon() }
        sessions[pane.id] = session
        Task {
            await session.start(initialPrompt: prompt)
            if focusWhenReady, restoration.focusedPane == pane.id, sessions[pane.id] === session { session.focus() }
        }
    }
    @discardableResult
    func addPane(kind: PaneKind = .codex, title: String? = nil, options: CodexOptions? = nil, split: SplitAxis? = nil, prompt: String? = nil) -> UUID? {
        let oldLayout = layout, oldRestoration = restoration
        let pane = PaneDefinition(title: title ?? (kind == .codex ? "Codex \(layout.panes.filter { $0.kind == .codex }.count + 1)" : "Terminal"), kind: kind, options: options ?? definition.defaults)
        if let split, let target = restoration.focusedPane ?? layout.panes.first?.id {
            if layout.tree == nil { layout.tree = makeTree(layout.panes.map(\.id)) }
            layout.tree = layout.tree?.splitting(target, with: pane.id, axis: split); layout.automatic = false
        } else if let tree = layout.tree { layout.tree = .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: tree, second: .pane(pane.id)) }
        else { layout.tree = .pane(pane.id) }
        if split == nil { layout.automatic = true }
        layout.panes.append(pane); restoration.focusedPane = pane.id; restoration.maximizedPane = nil; restoration.selectedTab = "Code"
        guard saveNow() else { layout = oldLayout; restoration = oldRestoration; return nil }; ensureSession(pane, prompt: prompt, focusWhenReady: true); return pane.id
    }
    func makeTree(_ ids: [UUID]) -> LayoutNode? {
        guard let first = ids.first else { return nil }
        return ids.dropFirst().reduce(.pane(first)) { .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: $0, second: .pane($1)) }
    }
    func closePane(_ id: UUID, finished: TerminalSnapshot? = nil) {
        guard closingPanes.insert(id).inserted else { return }
        Task {
            defer { closingPanes.remove(id) }
            do {
                if let finished, let pane = layout.panes.first(where: { $0.id == id }) {
                    _ = try? await backend.checkpoint(pane, running: finished)
                }
                if await backend.exists(id) { try await backend.stop(id) }
                sessions[id]?.disconnect(); sessions.removeValue(forKey: id)
                layout.panes.removeAll { $0.id == id }; layout.tree = layout.tree?.removing(id)
                restoration.detachedPanes.removeValue(forKey: id)
                if restoration.focusedPane == id { restoration.focusedPane = layout.panes.first?.id }
                if restoration.maximizedPane == id { restoration.maximizedPane = nil }
                saveNow()
                if let focused = restoration.focusedPane { sessions[focused]?.focus() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func closeFile() {
        guard codeDocument.save() else { return }
        restoration.selectedFile = nil
        if let id = restoration.focusedPane { sessions[id]?.focus() }
        saveSoon()
    }
    private func refreshExitedPanes() async {
        for snapshot in await backend.snapshot() where snapshot.exitedSuccessfully {
            guard sessions[snapshot.paneID] != nil else { continue }
            closePane(snapshot.paneID, finished: snapshot)
        }
    }
    func restartPane(_ id: UUID) {
        guard let pane = layout.panes.first(where: { $0.id == id }) else { return }
        Task {
            do { if await backend.exists(id) { try await backend.stop(id) }; sessions[id]?.disconnect(); sessions.removeValue(forKey: id); ensureSession(pane) }
            catch { self.error = error.localizedDescription }
        }
    }
    func renamePane(_ id: UUID, title: String) {
        if let index = layout.panes.firstIndex(where: { $0.id == id }) { layout.panes[index].title = title; saveSoon() }
    }
    func movePane(_ source: UUID, before target: UUID) {
        guard source != target, let sourceIndex = layout.panes.firstIndex(where: { $0.id == source }) else { return }
        let pane = layout.panes.remove(at: sourceIndex)
        layout.panes.insert(pane, at: layout.panes.firstIndex(where: { $0.id == target }) ?? layout.panes.count)
        layout.tree = makeTree(layout.panes.map(\.id)); layout.automatic = true; saveSoon()
    }
    func focusNext(direction: Int = 1) {
        let ids = layout.panes.map(\.id)
        guard !ids.isEmpty else { return }
        let next = ((ids.firstIndex(of: restoration.focusedPane ?? ids[0]) ?? -1) + direction + ids.count) % ids.count
        restoration.focusedPane = ids[next]; sessions[ids[next]]?.focus(); saveSoon()
    }
    func maximize(_ id: UUID) { restoration.maximizedPane = restoration.maximizedPane == id ? nil : id; saveSoon() }
    func saveSoon() {
        pendingSave = true; saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(300)); guard !Task.isCancelled else { return }; saveNow() }
    }
    @discardableResult func saveNow() -> Bool {
        saveTask?.cancel()
        do {
            let currentDefinition = try? Data(contentsOf: paths.definition), currentLayout = try? Data(contentsOf: paths.layout)
            guard currentDefinition == savedDefinition, currentLayout == savedLayout else {
                try DurableFile.save(layout, to: paths.local.appendingPathComponent("layout-conflict.json"))
                throw FreemindError.message("Workspace settings changed externally. Your layout is preserved in local/layout-conflict.json. Reload the workspace to use the disk version.")
            }
            try DurableFile.save(definition, to: paths.definition); savedDefinition = try? Data(contentsOf: paths.definition)
            try DurableFile.save(layout, to: paths.layout); savedLayout = try? Data(contentsOf: paths.layout)
            try DurableFile.save(restoration, to: paths.restoration)
            pendingSave = false
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func reloadFromDisk() {
        do {
            definition = try DurableFile.load(WorkspaceDefinition.self, from: paths.definition)
            layout = try DurableFile.load(WorkspaceLayout.self, from: paths.layout)
            savedDefinition = try? Data(contentsOf: paths.definition); savedLayout = try? Data(contentsOf: paths.layout)
            if FileManager.default.fileExists(atPath: paths.comments.path) {
                comments = try DurableFile.load([CodeComment].self, from: paths.comments)
                savedComments = try? Data(contentsOf: paths.comments)
            }
            pendingSave = false; error = nil
            if initialized { for pane in layout.panes { ensureSession(pane) } }
        } catch { self.error = error.localizedDescription }
    }
    private func diskChanged() {
        externalRevision += 1
        if (try? Data(contentsOf: paths.comments)) != savedComments,
           let updated = try? DurableFile.load([CodeComment].self, from: paths.comments) {
            comments = updated; savedComments = try? Data(contentsOf: paths.comments)
        }
        if !pendingSave, (try? Data(contentsOf: paths.definition)) != savedDefinition || (!pendingSave && (try? Data(contentsOf: paths.layout)) != savedLayout) { reloadFromDisk() }
        git.refreshSoon()
    }
    func checkpoint() async {
        let snapshots = await backend.snapshot()
        for pane in layout.panes {
            guard let session = sessions[pane.id] else { continue }
            let snapshot = snapshots.first { $0.paneID == pane.id }
            if let snapshot, snapshot.exitedSuccessfully { closePane(pane.id, finished: snapshot); continue }
            do {
                let recovery = try await backend.checkpoint(pane, running: snapshot)
                guard sessions[pane.id] === session else { continue }
                session.status = snapshot?.running == false ? "Exited\(snapshot?.exitStatus.map { " (status \($0))" } ?? "")" : recovery.lastStatus
                session.running = snapshot?.running == true
                session.conversationID = recovery.conversationID
            } catch { session.error = error.localizedDescription }
        }
        refreshHookStatus()
    }
    private func refreshHookStatus() {
        for (id, session) in sessions where session.running {
            let directory = paths.terminal(id)
            guard let event = try? DurableFile.load(HookEvent.self, from: directory.appendingPathComponent("event.json")) else { continue }
            let primary = try? DurableFile.load(HookEvent.self, from: directory.appendingPathComponent("session.json"))
            guard primary?.sessionID == nil || primary?.sessionID == event.sessionID else { continue }
            session.receive(event)
        }
    }
    func exportHistory(_ pane: PaneDefinition) {
        Task {
            do {
                let output = try await backend.capture(pane.id)
                let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                let filename = "\(pane.id.uuidString)-\(Int(Date().timeIntervalSince1970)).md"
                let url = paths.metadata.appendingPathComponent("history/\(filename)")
                try Data(("# \(pane.title)\n\n```text\n" + clean + "\n```\n").utf8).write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription }
        }
    }
    func submit(_ comment: CodeComment) {
        guard (try? Data(contentsOf: paths.comments)) == savedComments else { error = "Comments changed on disk. Reopen the workspace before adding another comment."; return }
        var value = comment
        value.paneID = addPane(title: "Review · " + URL(fileURLWithPath: value.file).lastPathComponent, prompt: value.prompt)
        guard value.paneID != nil else { return }
        comments.append(value)
        do { try DurableFile.save(comments, to: paths.comments); savedComments = try? Data(contentsOf: paths.comments) } catch { self.error = error.localizedDescription }
    }
}
