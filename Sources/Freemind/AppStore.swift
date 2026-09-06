import AppKit
import SwiftUI
import FreemindCore

enum AppPaths {
    static var settings: URL { registry.deletingLastPathComponent().appendingPathComponent("settings.json") }
    static var tmux: String { Bundle.main.resourceURL?.appendingPathComponent("bin/tmux").path ?? "" }
    static var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/freemind-helper").path }
    static var registry: URL {
        if let path = ProcessInfo.processInfo.environment["FREEMIND_REGISTRY"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Freemind/registry.json")
    }
}
struct WorkspaceReference: Codable, Identifiable {
    var path: String
    var bookmark: Data?
    var id: String { path }
}
struct Registry: Codable {
    var schemaVersion = 1
    var workspaces: [WorkspaceReference] = []
    var selectedPath: String?
}

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published var workspaces: [WorkspaceModel] = []
    @Published var missing: [WorkspaceReference] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published var loading = true
    @Published var environment = ProcessInfo.processInfo.environment
    @Published private(set) var settings = AppSettings()
    var quitting = false
    private var started = false
    var selected: WorkspaceModel? { workspaces.first { $0.id == selectedID } }
    var registry = Registry()

    init() {
        do { settings = try AppSettings.load(from: AppPaths.settings) }
        catch { self.error = "Could not load app settings: " + error.localizedDescription }
    }

    func saveSettings(_ value: AppSettings) throws {
        try value.save(to: AppPaths.settings)
        settings = value
        applyAppearance()
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func start(openWindow: OpenWindowAction) async {
        guard !started else { return }; started = true
        do {
            let shell = environment["SHELL"] ?? "/bin/zsh"
            let result = try await CommandRunner.run(shell, ["-lic", "/usr/bin/env -0"], timeout: 10)
            if result.code == 0 {
                for pair in result.output.split(separator: "\0") {
                    guard let equal = pair.firstIndex(of: "=") else { continue }
                    let key = String(pair[..<equal])
                    if key.range(of: "^[A-Za-z_][A-Za-z_0-9]*$", options: .regularExpression) != nil { environment[key] = String(pair[pair.index(after: equal)...]) }
                }
            }
        } catch { /* Explicit executable configuration remains available. */ }
        let registryURL = AppPaths.registry
        registry = await Task.detached { (try? DurableFile.load(Registry.self, from: registryURL)) ?? Registry() }.value
        for ref in registry.workspaces {
            var url = URL(fileURLWithPath: ref.path)
            if let bookmark = ref.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale) { url = resolved }
            }
            do {
                let workspace = try WorkspaceModel(root: url, environment: environment, defaults: settings.workspaceDefaults); workspaces.append(workspace)
                if ref.path == registry.selectedPath { selectedID = workspace.id }
            } catch { missing.append(ref) }
        }
        if let path = ProcessInfo.processInfo.environment["FREEMIND_OPEN_FOLDER"] { add(URL(fileURLWithPath: path)) }
        if selectedID == nil { selectedID = workspaces.first?.id }
        loading = false
        for workspace in workspaces {
            workspace.activate()
            if workspace.restoration.windowOpen { openWindow(id: "workspace", value: workspace.id.uuidString) }
            for id in workspace.restoration.detachedPanes.keys { openWindow(id: "terminal", value: "\(workspace.id.uuidString)/\(id.uuidString)") }
        }
        saveRegistry()
    }
    func pickFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Choose folders to open as workspaces. Workspace data stays in each folder."
        panel.prompt = "Open Workspace"
        if panel.runModal() == .OK { for url in panel.urls { add(url) } }
    }
    func add(_ url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = workspaces.first(where: { $0.paths.root == canonical }) { selectedID = existing.id; return }
        do {
            let workspace = try WorkspaceModel(root: canonical, environment: environment, defaults: settings.workspaceDefaults)
            workspaces.append(workspace); selectedID = workspace.id
            missing.removeAll { $0.path == canonical.path }
            workspace.activate(); saveRegistry()
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ workspace: WorkspaceModel) {
        workspace.saveNow()
        for session in workspace.sessions.values { session.disconnect() }
        workspaces.removeAll { $0.id == workspace.id }
        if selectedID == workspace.id { selectedID = workspaces.first?.id }
        saveRegistry()
    }
    func select(_ id: UUID) { selectedID = id; selected?.activate(); saveRegistry() }
    func move(from: IndexSet, to: Int) { workspaces.move(fromOffsets: from, toOffset: to); saveRegistry() }
    func togglePinned(_ workspace: WorkspaceModel) {
        workspace.definition.pinned.toggle(); workspace.saveNow()
        workspaces = workspaces.enumerated().sorted { a, b in
            if a.element.definition.pinned != b.element.definition.pinned { return a.element.definition.pinned }
            return a.offset < b.offset
        }.map(\.element)
        saveRegistry()
    }
    func saveRegistry() {
        registry.workspaces = workspaces.map { WorkspaceReference(path: $0.paths.root.path, bookmark: try? $0.paths.root.bookmarkData(options: .suitableForBookmarkFile)) } + missing
        registry.selectedPath = selected?.paths.root.path
        do { try DurableFile.save(registry, to: AppPaths.registry) } catch { self.error = error.localizedDescription }
    }
    func prepareToQuit(stop: Bool = false) async {
        quitting = true
        NotificationCenter.default.post(name: .freemindSave, object: nil)
        for workspace in workspaces { _ = workspace.codeDocument.save(); _ = workspace.notesDocument.save(); workspace.saveNow(); await workspace.checkpoint(); if stop { await workspace.backend.stopAll() }; for session in workspace.sessions.values { session.disconnect() } }
        saveRegistry()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStore.shared.applyAppearance()
        CommandRouter.shared.install()
        AppUpdater.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppStore.shared.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationDidBecomeActive(_ notification: Notification) { for item in AppStore.shared.workspaces { item.git.refreshSoon() } }
}

struct WindowTracker: NSViewRepresentable {
    var restored: FreemindCore.WindowPlacement?
    var workspaceID: UUID? = nil
    var windowReady: (Int) -> Void = { _ in }
    var changed: (FreemindCore.WindowPlacement) -> Void
    var closed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { context.coordinator.install(window) } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.parent = self; if let window = nsView.window { if let id = workspaceID { CommandRouter.shared.windows[window.windowNumber] = id }; DispatchQueue.main.async { windowReady(window.windowNumber) } } }
    @MainActor final class Coordinator {
        var parent: WindowTracker
        var observers: [NSObjectProtocol] = []
        init(_ parent: WindowTracker) { self.parent = parent }
        @MainActor func install(_ window: NSWindow) {
            window.titleVisibility = .hidden
            if let id = parent.workspaceID { CommandRouter.shared.windows[window.windowNumber] = id }
            parent.windowReady(window.windowNumber)
            if let placement = parent.restored {
                var frame = NSRect(x: placement.x, y: placement.y, width: max(600, placement.width), height: max(400, placement.height))
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
                    frame.size.width = min(frame.width, visible.width); frame.size.height = min(frame.height, visible.height); frame.origin = visible.origin
                }
                window.setFrame(frame, display: true)
            }
            for notification in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: notification, object: window, queue: .main) { [weak self, weak window] _ in
                  MainActor.assumeIsolated {
                    guard let frame = window?.frame else { return }
                    self?.parent.changed(WindowPlacement(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
                  }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.parent.closed() } })
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
