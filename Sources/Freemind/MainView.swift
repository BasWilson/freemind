import SwiftUI
import AppKit
import FreemindCore

struct MainView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarSelection: SidebarSelection?
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                HStack {
                    Text("WORKSPACES").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    Spacer()
                    Button { store.pickFolder() } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                        .buttonStyle(.borderless).help("Open Workspace (⌘O)")
                }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                List(selection: $sidebarSelection) {
                    ForEach(store.workspaces) { workspace in
                        WorkspaceRow(workspace: workspace, store: store, selection: $sidebarSelection)
                    }.onMove(perform: store.move)
                    ForEach(store.missing) { ref in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(URL(fileURLWithPath: ref.path).lastPathComponent, systemImage: "folder.badge.questionmark")
                            Text("Folder unavailable").font(.caption).foregroundStyle(.secondary)
                            Button("Locate Folder…") { store.pickFolder() }
                        }.contextMenu { Button("Remove Reference") { store.missing.removeAll { $0.id == ref.id }; store.saveRegistry() } }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 26).tint(theme.accent)
                    .onChange(of: sidebarSelection) { _, item in selectSidebar(item) }
                    .onChange(of: store.selectedID) { _, id in
                        if let id, sidebarSelection?.workspaceID != id { sidebarSelection = .workspace(id) }
                    }
                Divider().overlay(theme.border)
                Button { CommandRouter.shared.run("palette") } label: {
                    HStack(spacing: 8) { Image(systemName: "command"); Text("Commands"); Spacer(); Text("⌘K").font(.system(size: 10, design: .monospaced)) }
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
                }.buttonStyle(.plain).help("Commands and keyboard shortcuts (⌘K)")
            }.background(theme.panel.opacity(0.55)).navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } detail: {
          VStack(spacing: 0) {
            if store.loading { ProgressView("Opening workspaces…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let workspace = store.selected { WorkspaceView(workspace: workspace).id(workspace.id) }
            else {
                VStack(spacing: 20) {
                    Image(systemName: "terminal").font(.system(size: 42, weight: .light)).foregroundStyle(theme.accent)
                    Text("Room for your next idea.").font(.system(size: 28, weight: .semibold))
                    Text("Open a folder to bring your terminals, code, Git, and notes together.").foregroundStyle(.secondary)
                    Button("Open Workspace…") { store.pickFolder() }.buttonStyle(.borderedProminent).tint(theme.accent)
                    Text("Your workspace stays in your folder.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
        .frame(minWidth: 900, minHeight: 580)
        .navigationSplitViewStyle(.balanced)
        .task { await store.start(openWindow: openWindow) }
        .alert("Freemind", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func selectSidebar(_ item: SidebarSelection?) {
        guard let item, let workspace = store.workspaces.first(where: { $0.id == item.workspaceID }) else { return }
        store.select(workspace.id)
        switch item {
        case .workspace: break
        case .terminal(_, let id):
            workspace.restoration.selectedTab = "Code"; workspace.restoration.focusedPane = id
            if workspace.restoration.maximizedPane != nil { workspace.restoration.maximizedPane = id }
            if workspace.restoration.detachedPanes[id] != nil { openWindow(id: "terminal", value: "\(workspace.id.uuidString)/\(id.uuidString)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { workspace.sessions[id]?.focus() }
        case .file(_, let path): workspace.restoration.selectedTab = "Code"; workspace.restoration.selectedFile = path
        }
        workspace.saveSoon()
    }
}

enum SidebarSelection: Hashable {
    case workspace(UUID), terminal(UUID, UUID), file(UUID, String)
    var workspaceID: UUID {
        switch self { case .workspace(let id), .terminal(let id, _), .file(let id, _): return id }
    }
}
struct WorkspaceRow: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var store: AppStore
    @Binding var selection: SidebarSelection?
    @Environment(\.openWindow) private var openWindow
    @State private var editing = false
    private var hasChildren: Bool { !workspace.layout.panes.isEmpty || workspace.restoration.selectedFile != nil }
    private var expanded: Binding<Bool> {
        Binding(get: { workspace.restoration.sidebarExpanded ?? true }, set: { workspace.restoration.sidebarExpanded = $0; workspace.saveSoon() })
    }
    var body: some View {
        Group {
            if hasChildren {
                DisclosureGroup(isExpanded: expanded) {
                    ForEach(workspace.layout.panes) { pane in
                        HStack(spacing: 7) {
                            Label(pane.title.isEmpty ? "Untitled terminal" : pane.title, systemImage: "terminal").lineLimit(1)
                            Spacer(minLength: 2)
                            if let session = workspace.sessions[pane.id] { SessionIndicator(session: session) }
                        }.font(.system(size: 11)).frame(minHeight: 23)
                            .tag(SidebarSelection.terminal(workspace.id, pane.id))
                    }
                    if let path = workspace.restoration.selectedFile {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.text")
                            .font(.system(size: 11)).lineLimit(1).frame(minHeight: 23)
                            .tag(SidebarSelection.file(workspace.id, path))
                    }
                } label: { workspaceLabel }
                    .tag(SidebarSelection.workspace(workspace.id))
            } else { workspaceLabel.tag(SidebarSelection.workspace(workspace.id)) }
        }
        .contextMenu {
            Button("Rename Workspace…") { editing = true }
            Button("Open in New Window") { workspace.restoration.windowOpen = true; workspace.saveSoon(); openWindow(id: "workspace", value: workspace.id.uuidString) }
            Button(workspace.definition.pinned ? "Unpin" : "Pin") { store.togglePinned(workspace) }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.paths.root.path) }
            Button("Remove from Sidebar") { store.remove(workspace) }
        }
        .onChange(of: workspace.restoration.focusedPane) { _, id in
            if store.selectedID == workspace.id, let id { selection = .terminal(workspace.id, id) }
        }
    }
    private var workspaceLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: workspace.definition.pinned ? "pin.fill" : "folder").foregroundStyle(.secondary)
            if editing {
                TextField("Workspace name", text: $workspace.definition.name).textFieldStyle(.plain)
                    .onSubmit { editing = false; workspace.saveSoon() }
            } else { Text(workspace.definition.name).lineLimit(1) }
            Spacer(minLength: 2)
            if !workspace.layout.panes.isEmpty { Text("\(workspace.layout.panes.count)").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.font(.system(size: 12, weight: .medium)).frame(minHeight: 25).help(workspace.paths.root.path)
    }
}

extension URL { var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath } }

struct WorkspaceView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    var standalone = false
    @State private var windowID = -1
    @State private var newPane = false
    @State private var defaults = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            GitErrorBanner(model: workspace.git)
            if let error = workspace.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.caption); Spacer(); Button("Reload") { workspace.reloadFromDisk() }; Button { workspace.error = nil } label: { Image(systemName: "xmark") } }
                    .foregroundStyle(.orange).padding(10).background(Color.orange.opacity(0.08))
            }
            switch workspace.restoration.selectedTab {
            case "Git": GitView(workspace: workspace, model: workspace.git)
            case "Notes": NotesView(workspace: workspace)
            default: CodeView(workspace: workspace, newPane: { newPane = true })
            }
        }.environment(\.workspaceWindowID, windowID)
        .background(theme.background).tint(theme.accent).frame(minWidth: 660, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 10) {
                    Text(workspace.definition.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .help(workspace.paths.root.path)
                    GitBranchButton(model: workspace.git)
                }.padding(.horizontal, 8).padding(.vertical, 5)
            }
            ToolbarItem(placement: .principal) {
                WorkspaceTabs(selection: $workspace.restoration.selectedTab).onChange(of: workspace.restoration.selectedTab) { _, _ in workspace.saveSoon() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Terminal…") { newPane = true }
                    Button("Terminal Defaults…") { defaults = true }
                    Divider()
                    Button("Commands & Shortcuts…") { CommandRouter.shared.run("palette") }
                    Button("Open Workspace in New Window") { workspace.restoration.windowOpen = true; workspace.saveSoon(); openWindow(id: "workspace", value: workspace.id.uuidString) }
                    Button("Reload Workspace Files") { workspace.reloadFromDisk() }
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.paths.root.path) }
                } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).help("Workspace actions")
            }
        }
        .workspaceToolbarTitle()
        .onReceive(NotificationCenter.default.publisher(for: .freemindCommand)) { message in
            guard message.object as? UUID == workspace.id, message.userInfo?["window"] as? Int == windowID else { return }
            if message.userInfo?["command"] as? String == "configure" { newPane = true }
        }
        .sheet(isPresented: $newPane) { NewPaneSheet(workspace: workspace) }
        .sheet(isPresented: $defaults) { NewPaneSheet(workspace: workspace, defaultsOnly: true) }
        .background(WindowTracker(restored: workspace.restoration.window, workspaceID: workspace.id, windowReady: { if windowID != $0 { windowID = $0 } }, changed: { frame in workspace.restoration.window = frame; workspace.saveSoon() }, closed: {
            if !AppStore.shared.quitting && standalone { workspace.restoration.windowOpen = false; workspace.saveNow() }
        }))
        .onAppear { workspace.activate() }
        .task {
            // Linked worktrees can keep HEAD outside the folder watched for file changes.
            while !Task.isCancelled {
                await workspace.git.refreshCurrentBranch()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await workspace.git.refresh() }
        }
        .onChange(of: workspace.restoration) { _, _ in workspace.saveSoon() }

    }
}

struct DetachedTerminalWindow: View {
    @ObservedObject var store: AppStore
    let key: String
    var body: some View {
        let parts = key.split(separator: "/")
        if parts.count == 2, let workspace = store.workspaces.first(where: { $0.id.uuidString == parts[0] }),
           let id = UUID(uuidString: String(parts[1])) {
            DetachedPaneContent(store: store, workspace: workspace, id: id)
        } else { Text("This terminal has been closed.").padding(40) }
    }
}

private struct DetachedPaneContent: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var store: AppStore
    @ObservedObject var workspace: WorkspaceModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let pane = workspace.layout.panes.first(where: { $0.id == id }) {
            TerminalCard(workspace: workspace, pane: pane, detached: true).padding(8).background(theme.background)
                .background(WindowTracker(restored: workspace.restoration.detachedPanes[id], workspaceID: workspace.id, changed: { workspace.restoration.detachedPanes[id] = $0; workspace.saveSoon() }, closed: {
                    if !store.quitting { workspace.restoration.detachedPanes.removeValue(forKey: id); workspace.saveSoon() }
                }))
        } else { Color.clear.onAppear { dismiss() } }
    }
}

struct WorkspaceTabs: View {
    @Binding var selection: String
    var body: some View {
        Picker("Workspace view", selection: $selection) {
            Text("Code").tag("Code")
            Text("Git").tag("Git")
            Text("Notes").tag("Notes")
        }.pickerStyle(.segmented).labelsHidden().controlSize(.regular).frame(width: 204).padding(.vertical, 4)
            .help("Code ⌘1 · Git ⌘2 · Notes ⌘3")

    }
}
struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonContent(configuration: configuration)
    }
    private struct ChromeButtonContent: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label.padding(5).contentShape(RoundedRectangle(cornerRadius: 6))
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}
