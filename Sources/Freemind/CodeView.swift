import SwiftUI
import AppKit
import FreemindCore

struct CodeView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    let newPane: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { workspace.restoration.filesVisible.toggle(); workspace.saveSoon() } label: { Label("Files", systemImage: "sidebar.left") }
                    .foregroundStyle(workspace.restoration.filesVisible ? theme.accent : .secondary)
                Text("\(workspace.layout.panes.count) terminals").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 12) {
                    Button { workspace.layout.automatic = true; workspace.restoration.maximizedPane = nil; workspace.saveSoon() } label: { Image(systemName: "square.grid.2x2") }.help("Auto Arrange (⌥⌘A)")
                    Divider().frame(height: 12)
                    Button(action: newPane) { Label("New Terminal", systemImage: "plus") }.help("Configure and create a terminal (⌥⌘T)")
                }.padding(.horizontal, 10).padding(.vertical, 6).navigationGlass(cornerRadius: 14)
            }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 5)
            // Keep the terminal subtree at the same structural identity. Only the
            // surrounding splits change size when a browser or editor opens.
            WorkspaceColumns(initial: 220, leadingVisible: workspace.restoration.filesVisible, savedWidth: $workspace.restoration.fileBrowserWidth) {
                if workspace.restoration.filesVisible { FilesPanel(workspace: workspace) }
            } trailing: { editorAndTerminals }
        }.transaction { $0.animation = nil }
    }
    @ViewBuilder private var editorAndTerminals: some View {
        WorkspaceRows(topVisible: workspace.restoration.selectedFile != nil, savedFraction: $workspace.restoration.editorFraction) {
            if workspace.restoration.selectedFile != nil { CodeEditorPanel(workspace: workspace) }
        } bottom: { TerminalCanvas(workspace: workspace, newPane: newPane) }
    }

}

struct TerminalCanvas: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    let newPane: () -> Void
    var panes: [PaneDefinition] { workspace.layout.panes.filter { workspace.restoration.detachedPanes[$0.id] == nil } }
    var body: some View {
        if panes.isEmpty {
            VStack(spacing: 18) {
                Image(systemName: "terminal").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(theme.accent.opacity(0.7))
                Text(workspace.layout.panes.isEmpty ? "A fresh place to work." : "Your terminals are in separate windows.").font(.system(size: 20, weight: .medium))
                Text("Open Codex or a shell in this folder.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("New Codex Terminal", action: newPane).buttonStyle(.borderedProminent)
                    Button("Open Shell") { workspace.addPane(kind: .shell) }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let id = workspace.restoration.maximizedPane, let pane = panes.first(where: { $0.id == id }) {
            TerminalCard(workspace: workspace, pane: pane).padding(10)
        } else {
            GeometryReader { geometry in
                if workspace.layout.automatic {
                    ScrollViewReader { proxy in
                      ScrollView(.vertical) {
                        TerminalGridLayout(viewportHeight: geometry.size.height - 20) {
                            // A flat collection preserves every native terminal view
                            // when the number of columns or rows changes.
                            ForEach(panes) { pane in
                                TerminalCard(workspace: workspace, pane: pane).clipped().id(pane.id)
                            }
                        }.padding(10).frame(width: geometry.size.width)
                      }.onChange(of: workspace.restoration.focusedPane) { _, id in
                          if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                      }
                    }
                } else if let tree = visibleTree {
                    let minimum = minimumSize(tree)
                    ScrollView([.horizontal, .vertical]) {
                        SplitNodeView(workspace: workspace, node: tree)
                            .frame(width: max(geometry.size.width - 20, minimum.width), height: max(geometry.size.height - 20, minimum.height)).padding(10)
                    }
                }
            }
        }
    }
    var visibleTree: LayoutNode? {
        var tree = workspace.layout.tree
        for id in workspace.restoration.detachedPanes.keys { tree = tree?.removing(id) }
        return tree
    }
    func minimumSize(_ node: LayoutNode) -> CGSize {
        switch node {
        case .pane: return CGSize(width: 300, height: 200)
        case .split(_, let axis, _, let a, let b):
            let x = minimumSize(a), y = minimumSize(b)
            return axis == .horizontal ? CGSize(width: x.width + y.width + 8, height: max(x.height,y.height)) : CGSize(width: max(x.width,y.width), height: x.height + y.height + 8)
        }
    }
}

struct TerminalGridLayout: Layout {
    var viewportHeight: CGFloat
    private func metrics(count: Int, width: CGFloat) -> (PaneGrid, CGFloat) {
        let grid = PaneGrid(count: count, width: width + 20)
        let height = max(240, (viewportHeight - CGFloat(max(0, grid.rows - 1)) * 8) / CGFloat(max(1, grid.rows)))
        return (grid, height)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 800)
        let (grid, height) = metrics(count: subviews.count, width: width)
        return CGSize(width: width, height: CGFloat(grid.rows) * height + CGFloat(max(0, grid.rows - 1)) * 8)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (grid, height) = metrics(count: subviews.count, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            let row = index / grid.columns, column = index % grid.columns
            let count = min(grid.columns, subviews.count - row * grid.columns)
            let width = max(1, (bounds.width - CGFloat(count - 1) * 8) / CGFloat(count))
            view.place(at: CGPoint(x: bounds.minX + CGFloat(column) * (width + 8), y: bounds.minY + CGFloat(row) * (height + 8)),
                       anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

struct SplitNodeView: View {
    @ObservedObject var workspace: WorkspaceModel
    let node: LayoutNode
    @State private var initialRatio: Double?
    var body: some View {
        switch node {
        case .pane(let id):
            if let pane = workspace.layout.panes.first(where: { $0.id == id }) { TerminalCard(workspace: workspace, pane: pane) }
        case .split(let id, let axis, let ratio, let a, let b):
            GeometryReader { geometry in
                let length = max(1, (axis == .horizontal ? geometry.size.width : geometry.size.height) - 8)
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        AnyView(SplitNodeView(workspace: workspace, node: a)).frame(width: length * ratio)
                        divider(id, axis, ratio, length)
                        AnyView(SplitNodeView(workspace: workspace, node: b)).frame(width: length * (1-ratio))
                    }
                } else {
                    VStack(spacing: 0) {
                        AnyView(SplitNodeView(workspace: workspace, node: a)).frame(height: length * ratio)
                        divider(id, axis, ratio, length)
                        AnyView(SplitNodeView(workspace: workspace, node: b)).frame(height: length * (1-ratio))
                    }
                }
            }
        }
    }
    func divider(_ id: UUID, _ axis: SplitAxis, _ ratio: Double, _ length: Double) -> some View {
        Rectangle().fill(Color.primary.opacity(initialRatio == nil ? 0.04 : 0.16))
            .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
            .contentShape(Rectangle()).onHover { inside in if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if initialRatio == nil { initialRatio = ratio }
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                workspace.layout.tree = workspace.layout.tree?.settingRatio(id, (initialRatio ?? ratio) + delta / length)
            }.onEnded { _ in initialRatio = nil; workspace.saveSoon() })
    }
}

struct TerminalCard: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    let pane: PaneDefinition
    var detached = false
    @Environment(\.openWindow) private var openWindow
    @State private var showHistory = false
    @State private var confirmClose = false
    var focused: Bool { workspace.restoration.focusedPane == pane.id }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let session = workspace.sessions[pane.id] { SessionIndicator(session: session) }
                Image(systemName: pane.kind == .codex ? "sparkle" : "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Terminal title", text: Binding(get: { workspace.layout.panes.first(where: { $0.id == pane.id })?.title ?? pane.title }, set: { workspace.renamePane(pane.id, title: $0) }))
                    .font(.system(size: 11, weight: .medium)).textFieldStyle(.plain).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Split Right") { workspace.restoration.focusedPane = pane.id; workspace.addPane(split: .horizontal) }
                    Button("Split Below") { workspace.restoration.focusedPane = pane.id; workspace.addPane(split: .vertical) }
                    if !detached { Button("Open in Separate Window") {
                        workspace.restoration.detachedPanes[pane.id] = WindowPlacement(x: 100, y: 100, width: 900, height: 650)
                        workspace.saveSoon(); openWindow(id: "terminal", value: "\(workspace.id.uuidString)/\(pane.id.uuidString)")
                    } }
                    Divider()
                    Button("Show Saved Output") { showHistory = true }
                    Button("Export History to Workspace") { workspace.exportHistory(pane) }
                    Button("Restart / Resume") { workspace.restartPane(pane.id) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                if !detached {
                    Button { workspace.maximize(pane.id) } label: { Image(systemName: workspace.restoration.maximizedPane == pane.id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.help("Maximize terminal")
                }
                Button { confirmClose = true } label: { Image(systemName: "xmark") }.help("Close terminal and stop its process")
            }.buttonStyle(NativePaneButtonStyle()).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30).background(.bar)
                .draggable(pane.id.uuidString)
                .dropDestination(for: String.self) { values, _ in
                    guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                    workspace.movePane(id, before: pane.id); return true
                }
            Rectangle().fill(theme.border).frame(height: 1)
            if let session = workspace.sessions[pane.id] {
                TerminalContent(session: session, showHistory: { showHistory = true })
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(theme.background).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? theme.accent.opacity(0.65) : theme.border, lineWidth: 1))
        .confirmationDialog("Stop this terminal?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Stop and Close Terminal", role: .destructive) { workspace.closePane(pane.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The terminal’s running process will end. Its saved output remains in the workspace.") }
        .sheet(isPresented: $showHistory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved output · \(pane.title)").font(.headline)
                Text("A checkpoint from this workspace. Running output appears in the terminal.").font(.caption).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(history).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Done") { showHistory = false }.keyboardShortcut(.defaultAction)
            }.padding(22).frame(width: 850, height: 600)
        }
    }
    var history: String {
        ((try? String(contentsOf: workspace.paths.terminal(pane.id).appendingPathComponent("screen.ansi"), encoding: .utf8)) ?? "No saved output yet.")
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
struct SessionIndicator: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        Group {
            if session.error != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if session.needsAttention {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            } else if ["Working", "Compacting", "Starting"].contains(session.status) {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            } else if session.status == "Done" {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            } else {
                Circle().fill(session.running ? Color.secondary : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
            }
        }.font(.system(size: 10, weight: .semibold)).frame(width: 12, height: 12)
            .help(session.status).accessibilityLabel("Terminal status: \(session.status)")
    }
}
struct TerminalContent: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var session: TerminalSession
    let showHistory: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            if let error = session.error {
                VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle"); Text(error).font(.caption).textSelection(.enabled) }.foregroundStyle(.orange).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if session.recovered { HStack { Text("Session recovered"); Spacer(); Button("Previous output", action: showHistory) }.font(.system(size: 10)).padding(7).background(theme.accent.opacity(0.08)) }
                TerminalSurface(session: session)
                    .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
                        guard !providers.isEmpty else { return false }
                        Task { @MainActor in
                            var urls: [URL] = []
                            for provider in providers {
                                let data: Data? = await withCheckedContinuation { continuation in
                                    provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in continuation.resume(returning: data) }
                                }
                                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { urls.append(url) }
                            }
                            if !urls.isEmpty { session.view.insertFileURLs(urls) }
                        }
                        return true
                    }
                HStack { Text(session.status); Spacer(); if let id = session.conversationID { Text(String(id.prefix(8))) } }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).padding(.horizontal, 10).frame(height: 17)
            }
        }
    }
}
