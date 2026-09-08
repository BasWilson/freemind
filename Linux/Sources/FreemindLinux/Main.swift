import Foundation
import FreemindCore
import LinuxUI
import Glibc

// GTK owns the main thread. Swift actors run backend work away from it; the
// bridge queues every widget mutation back onto the GLib main context.
private final class UIAction {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}
func onUI(_ body: @escaping () -> Void) async {
    await withCheckedContinuation { continuation in
        let action = UIAction { body(); continuation.resume() }
        fm_post({ context in
            Unmanaged<UIAction>.fromOpaque(context!).takeRetainedValue().body()
        }, Unmanaged.passRetained(action).toOpaque())
    }
}

struct LinuxState: Codable {
    var lastWorkspace: String
    var workspaces: [String]?
    var sidebarWidth: Int?
    var sidebarVisible: Bool?
}
actor Controller {
    let environment = ProcessInfo.processInfo.environment
    let gate = OperationGate()
    var paths: WorkspacePaths?
    var backend: TerminalBackend?
    var definition: WorkspaceDefinition?
    var layout = WorkspaceLayout()
    var savedLayout: Data?
    var polling = false
    var shuttingDown = false
    var lastCheckpoint = Date.distantPast

    var workspaces: [String] = []
    var sidebarWidth = 230
    var sidebarVisible = true
    var restoration = Restoration()
    var expandedFolders = Set<String>()
    var fileQuery = "", noteQuery = ""
    var showHidden = false
    var codeDocument = WorkspaceDocument(), notesDocument = WorkspaceDocument()
    var diskDirty = false
    var lastDiskCheck = Date.distantPast
    var lastNoteEdit = Date.distantPast
    var lastRestorationSave = Date.distantPast
    var gitService: GitService?
    var gitSnapshot: GitSnapshot?
    var gitBranches: [GitBranch] = []
    var selectedChange: GitChange?
    var gitOperations = Set<String>()
    var gitWorking: Bool { gitOperations.contains(paths?.root.path ?? "") }
    var gitSplitDiff = false
    var gitFeedback = ""
    var lastGitCheck = Date.distantPast
    var renameTarget = "", renameWorkspaceTarget = ""
    var commentSelection: (Int, Int, String)?
    var paneKind = PaneKind.codex, paneTitle = "", paneSaveDefaults = false
    var statuses: [UUID: String] = [:]
    var settings = AppSettings()
    var savedSettings: Data?
    var settingsLoaded = false
    var themes = CustomThemeConfiguration()
    var savedThemes: Data?
    var observedThemes: Data?
    var defaultsDraft = CodexOptions()
    var defaultsScope = "global"
    var savedDefinition: Data?
    var themeDraft: CustomTheme?
    var themeVariant = "dark"
    var themeJSON = ""
    var themeRequest = ""
    var dark = true
    let updater = LinuxUpdater()

    var configFolder: URL {
        let root = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return URL(fileURLWithPath: root).appendingPathComponent("freemind")
    }
    var settingsURL: URL { configFolder.appendingPathComponent("settings.json") }
    var themesURL: URL { configFolder.appendingPathComponent("Themes/themes.json") }
    var stateURL: URL {
        let root = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
        return URL(fileURLWithPath: root).appendingPathComponent("freemind/linux.json")
    }

    func handle(_ action: String, value: String) async {
        if shuttingDown { return }
        if action == "poll" {
            guard !polling else { return }
            polling = true
        }
        await gate.acquire()
        do {
            if !shuttingDown { try await perform(action, value: value) }
        } catch {
            await onUI { fm_error(error.localizedDescription); fm_settings_message(error.localizedDescription, 1) }
        }
        if action == "poll" { polling = false }
        await gate.release()
    }

    private func perform(_ action: String, value: String) async throws {
        if try await handleWorkspace(action, value: value) { return }
        if try await handleSettings(action, value: value) { return }
        switch action {
        case "ready":
            do { try await loadSettings() }
            catch { await onUI { fm_error("Could not load settings: " + error.localizedDescription) } }
            let saved = try? DurableFile.load(LinuxState.self, from: stateURL)
            workspaces = saved?.workspaces ?? saved.map { [$0.lastWorkspace] } ?? []
            sidebarWidth = saved?.sidebarWidth ?? 230; sidebarVisible = saved?.sidebarVisible ?? true
            let width = sidebarWidth, visible = sidebarVisible
            await onUI { fm_sidebar(Int32(width), visible ? 1 : 0) }
            await refreshWorkspaces()
            if let initial = CommandLine.arguments.dropFirst().first { try await open(initial) }
            else if let saved, !saved.lastWorkspace.isEmpty { try await open(saved.lastWorkspace) }
            await refreshWorkspaces()
        case "open": try await open(value)
        case "shell", "codex":
            guard paths != nil else { throw FreemindError.message("Open a folder first.") }
            _ = try await createPane(kind: action == "shell" ? .shell : .codex)
        case "close":
            if let id = UUID(uuidString: value) { try await close(id) }
        case "restart":
            guard let id = UUID(uuidString: value), let pane = layout.panes.first(where: { $0.id == id }), let backend else { return }
            let snapshot = await backend.snapshot().first { $0.paneID == id }
            _ = try await backend.checkpoint(pane, running: snapshot)
            // A disconnected VTE client can reattach to a living session.
            // Only a dead session is stopped before recovery/restart.
            if let snapshot, !snapshot.running { try await backend.stop(id) }
            await onUI { fm_remove_pane(value) }
            try await attach(pane)
        case "left", "right":
            guard let id = UUID(uuidString: value), let index = layout.panes.firstIndex(where: { $0.id == id }) else { return }
            let position = max(0, min(layout.panes.count - 1, index + (action == "left" ? -1 : 1)))
            var updated = layout
            let pane = updated.panes.remove(at: index)
            updated.panes.insert(pane, at: position)
            updated.automatic = true
            updated.tree = makeTree(updated.panes.map(\.id))
            try save(updated)
            await onUI { fm_move_pane(value, Int32(position)) }
            await renderPaneLayout()
        case "poll": try await poll()
        case "quit":
            try await saveDocuments()
            try saveRestoration()
            try await checkpointAll()
            try await updater.installOnQuit()
            shuttingDown = true
            await onUI { fm_quit() }
        default: break
        }
    }

    func open(_ folder: String) async throws {
        let nextPaths = WorkspacePaths(root: URL(fileURLWithPath: folder, isDirectory: true))
        if paths?.root == nextPaths.root, (try? Data(contentsOf: nextPaths.layout)) == savedLayout, (try? Data(contentsOf: nextPaths.definition)) == savedDefinition { return }
        try nextPaths.initialize(defaults: settings.workspaceDefaults)
        let nextDefinition = try DurableFile.load(WorkspaceDefinition.self, from: nextPaths.definition)
        let nextLayout = try DurableFile.load(WorkspaceLayout.self, from: nextPaths.layout)
        let treeIDs = nextLayout.tree?.paneIDs
        guard nextLayout.schemaVersion == 1, Set(nextLayout.panes.map(\.id)).count == nextLayout.panes.count,
              treeIDs == nil || (Set(treeIDs!).count == treeIDs!.count && Set(treeIDs!) == Set(nextLayout.panes.map(\.id))) else {
            throw FreemindError.message("Unsupported or invalid workspace layout.")
        }
        let tmux = try executable("tmux", override: environment["FREEMIND_TMUX"])
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("freemind-helper").path
        let helper = try executable("freemind-helper", override: environment["FREEMIND_HELPER"] ?? sibling)
        try await saveDocuments()
        try saveRestoration()
        try await checkpoint()
        paths = nextPaths; definition = nextDefinition; layout = nextLayout
        savedDefinition = try Data(contentsOf: nextPaths.definition)
        savedLayout = try? Data(contentsOf: nextPaths.layout)
        backend = TerminalBackend(paths: nextPaths, executable: tmux, helper: helper, environment: environment)
        await onUI { fm_workspace(nextDefinition.name, nextPaths.root.path) }
        if !workspaces.contains(nextPaths.root.path) { workspaces.append(nextPaths.root.path) }
        try saveRegistry()
        restoration = (try? DurableFile.load(Restoration.self, from: nextPaths.restoration)) ?? Restoration()
        // The file tree is part of the Linux workspace from the first open.
        if !FileManager.default.fileExists(atPath: nextPaths.restoration.path) { restoration.filesVisible = true }
        expandedFolders = []; fileQuery = ""; noteQuery = ""; statuses = [:]
        codeDocument = WorkspaceDocument(draftURL: nextPaths.local.appendingPathComponent("code-draft.json"))
        notesDocument = WorkspaceDocument(draftURL: nextPaths.local.appendingPathComponent("notes-draft.json"))
        gitService = GitService(folder: nextPaths.root, environment: environment); gitSnapshot = nil; selectedChange = nil
        await onUI { fm_watch_clear(); fm_watch(nextPaths.root.path); fm_watch(nextPaths.metadata.path); fm_document("code", "", "", 0) }
        await refreshWorkspaces()
        try await refreshFiles()
        try await refreshNotes()
        if let file = restoration.selectedFile {
            do { try await openFile(file) } catch { await onUI { fm_error(error.localizedDescription) } }
        }
        await showContent()
        if let window = restoration.window { await onUI { fm_window_size(boundedPixels(window.width, fallback: 1380, minimum: 640), boundedPixels(window.height, fallback: 860, minimum: 480)) } }
        for pane in layout.panes {
            do { try await attach(pane) }
            catch { await onUI { fm_error(error.localizedDescription) } }
        }
        await renderPaneLayout()
        for (id, placement) in restoration.detachedPanes where layout.panes.contains(where: { $0.id == id }) { await onUI { fm_pane_detach(id.uuidString); fm_pane_window_size(id.uuidString, boundedPixels(placement.width, fallback: 1000, minimum: 300), boundedPixels(placement.height, fallback: 700, minimum: 240)) } }
        if let maximized = restoration.maximizedPane { await onUI { fm_pane_maximize(maximized.uuidString) } }
        if let focused = restoration.focusedPane { await onUI { fm_pane_focus(focused.uuidString) } }
        if restoration.selectedTab == "Git" { try await refreshGit() }
    }

    func executable(_ name: String, override: String?) throws -> String {
        let candidates = override.map { [$0] } ?? (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { "\($0)/\(name)" }
        guard let found = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FreemindError.message("Cannot find \(name). Build the Linux app and install tmux before opening a workspace.")
        }
        return found
    }

    func attach(_ pane: PaneDefinition) async throws {
        guard let backend, let paths else { return }
        var failure: Error?
        do { try await backend.start(pane) } catch { failure = error }
        let tmux = await backend.executable, socket = await backend.socket, session = await backend.sessionName(pane.id)
        let font = (try? DurableFile.load(Double.self, from: paths.terminal(pane.id).appendingPathComponent("font.json"))) ?? 11
        await onUI { fm_add_pane(pane.id.uuidString, pane.title, pane.kind.rawValue, tmux, socket, session, paths.root.path); fm_pane_font(pane.id.uuidString, font) }
        if let failure { throw failure }
    }

    func close(_ id: UUID) async throws {
        guard let backend, let pane = layout.panes.first(where: { $0.id == id }) else { return }
        try ensureUnchangedLayout()
        let snapshot = await backend.snapshot().first { $0.paneID == id }
        _ = try await backend.checkpoint(pane, running: snapshot)
        if await backend.exists(id) { try await backend.stop(id) }
        var updated = layout
        updated.panes.removeAll { $0.id == id }
        updated.tree = updated.tree?.removing(id)
        try save(updated)
        restoration.detachedPanes[id] = nil
        await onUI { fm_remove_pane(id.uuidString) }
        await renderPaneLayout()
    }

    private func ensureUnchangedLayout() throws {
        guard let paths else { return }
        guard (try? Data(contentsOf: paths.layout)) == savedLayout else {
            throw FreemindError.message("The layout changed on disk. Reopen the workspace before changing its panes.")
        }
    }
    func save(_ updated: WorkspaceLayout) throws {
        guard let paths else { return }
        try ensureUnchangedLayout()
        try DurableFile.save(updated, to: paths.layout)
        savedLayout = try Data(contentsOf: paths.layout)
        layout = updated
    }
    private func makeTree(_ ids: [UUID]) -> LayoutNode? {
        guard let first = ids.first else { return nil }
        return ids.dropFirst().reduce(LayoutNode.pane(first)) {
            .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: $0, second: .pane($1))
        }
    }

    private func poll() async throws {
        try await pollThemes()
        try await pollWorkspace()
        guard let backend, let paths else { return }
        let snapshots = await backend.snapshot()
        for pane in layout.panes {
            guard let snapshot = snapshots.first(where: { $0.paneID == pane.id }) else { continue }
            if snapshot.exitedSuccessfully { try await close(pane.id); continue }
            let event = try? DurableFile.load(HookEvent.self, from: paths.terminal(pane.id).appendingPathComponent("event.json"))
            let primary = try? DurableFile.load(HookEvent.self, from: paths.terminal(pane.id).appendingPathComponent("session.json"))
            let scoped = primary?.sessionID == nil || event?.sessionID == primary?.sessionID
            let status = snapshot.running ? (scoped ? event?.status ?? "Running" : "Running") : "Exited (\(snapshot.exitStatus ?? -1)) — Restart to recover"
            let changed = statuses[pane.id] != status
            statuses[pane.id] = status
            await onUI {
                fm_pane_status(pane.id.uuidString, status)
                if changed && ["Needs approval", "Done"].contains(status) { fm_notify(pane.id.uuidString, pane.title, status) }
            }
        }
        if Date().timeIntervalSince(lastCheckpoint) >= 3 { try await checkpoint() }
    }
    func checkpoint() async throws {
        guard let backend else { return }
        let snapshots = await backend.snapshot()
        for pane in layout.panes { _ = try await backend.checkpoint(pane, running: snapshots.first { $0.paneID == pane.id }) }
        lastCheckpoint = Date()
    }
}

let controller = Controller()
private var eventContinuation: AsyncStream<(String, String)>.Continuation?
@main
struct FreemindLinux {
    static func main() {
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.count > 2 {
            print("Usage: freemind-linux [workspace-folder]\nCtrl+Shift+O: open folder; Ctrl+Shift+T/N: new shell/Codex; Ctrl+Shift+Q: quit. Ctrl+Shift+C/V: copy/paste. Close panes to stop them; quit to preserve sessions.")
            return
        }
        let (events, continuation) = AsyncStream<(String, String)>.makeStream()
        Task.detached { for await (action, value) in events { await controller.handle(action, value: value) } }
        eventContinuation = continuation
        let result = fm_run { action, value in
            eventContinuation?.yield((String(cString: action!), String(cString: value!)))
        }
        exit(result)
    }
}

func boundedPixels(_ value: Double?, fallback: Double, minimum: Double) -> Int32 {
    let value = value.flatMap { $0.isFinite ? $0 : nil } ?? fallback
    return Int32(min(8192, max(minimum, value)))
}
