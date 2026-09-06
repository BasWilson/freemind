import AppKit
import SwiftUI
import FreemindCore

struct AppCommand: Identifiable {
    let id: String
    let title: String
    let group: String
    let key: String
    var modifiers: EventModifiers = [.command]
    var symbol = "command"
    var hint: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") +
        ["\r": "↩", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→"].defaulting(key.uppercased(), for: key)
    }
    static let all: [AppCommand] = [
        .init(id: "palette", title: "Show Commands", group: "Navigate", key: "k", symbol: "command"),
        .init(id: "quickOpen", title: "Quick Open File", group: "Navigate", key: "p", symbol: "doc.text.magnifyingglass"),
        .init(id: "open", title: "Open Workspace…", group: "File", key: "o", symbol: "folder.badge.plus"),
        .init(id: "newCodex", title: "New Codex Terminal", group: "Panes", key: "t", symbol: "terminal"),
        .init(id: "newShell", title: "New Shell Terminal", group: "Panes", key: "t", modifiers: [.command, .shift], symbol: "terminal.fill"),
        .init(id: "configure", title: "Configure New Terminal…", group: "Panes", key: "t", modifiers: [.command, .option], symbol: "slider.horizontal.3"),
        .init(id: "close", title: "Close Focused Panel", group: "File", key: "w", symbol: "xmark"),
        .init(id: "closeWindow", title: "Close Window", group: "File", key: "w", modifiers: [.command, .shift], symbol: "macwindow"),
        .init(id: "save", title: "Save File or Note", group: "File", key: "s", symbol: "square.and.arrow.down"),
        .init(id: "code", title: "Show Code", group: "Navigate", key: "1", symbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "git", title: "Show Git", group: "Navigate", key: "2", symbol: "arrow.triangle.branch"),
        .init(id: "notes", title: "Show Notes", group: "Navigate", key: "3", symbol: "note.text"),
        .init(id: "files", title: "Toggle File Explorer", group: "Navigate", key: "b", symbol: "sidebar.left"),
        .init(id: "nextWorkspace", title: "Next Workspace", group: "Navigate", key: "\u{F701}", modifiers: [.command, .option], symbol: "arrow.down"),
        .init(id: "previousWorkspace", title: "Previous Workspace", group: "Navigate", key: "\u{F700}", modifiers: [.command, .option], symbol: "arrow.up"),
        .init(id: "splitRight", title: "Split Right", group: "Panes", key: "d", symbol: "rectangle.split.2x1"),
        .init(id: "splitBelow", title: "Split Below", group: "Panes", key: "d", modifiers: [.command, .shift], symbol: "rectangle.split.1x2"),
        .init(id: "nextPane", title: "Focus Next Terminal", group: "Panes", key: "\u{F703}", modifiers: [.command, .option], symbol: "arrow.right"),
        .init(id: "previousPane", title: "Focus Previous Terminal", group: "Panes", key: "\u{F702}", modifiers: [.command, .option], symbol: "arrow.left"),
        .init(id: "maximize", title: "Toggle Maximized Terminal", group: "Panes", key: "m", modifiers: [.command, .shift], symbol: "arrow.up.left.and.arrow.down.right"),
        .init(id: "arrange", title: "Auto Arrange Terminals", group: "Panes", key: "a", modifiers: [.command, .option], symbol: "square.grid.2x2"),
        .init(id: "comment", title: "Comment on Selection → Codex", group: "File", key: "l", modifiers: [.command, .shift], symbol: "text.bubble"),
        .init(id: "refreshGit", title: "Refresh Git", group: "Git", key: "r", modifiers: [.command, .shift], symbol: "arrow.clockwise"),
        .init(id: "commit", title: "Commit Staged Changes", group: "Git", key: "\r", symbol: "checkmark"),
        .init(id: "commitPush", title: "Commit & Push", group: "Git", key: "\r", modifiers: [.command, .shift], symbol: "arrow.up.circle"),
        .init(id: "push", title: "Push", group: "Git", key: "p", modifiers: [.command, .option], symbol: "arrow.up"),
        .init(id: "zoomIn", title: "Increase Terminal Font", group: "Panes", key: "=", symbol: "plus.magnifyingglass"),
        .init(id: "zoomOut", title: "Decrease Terminal Font", group: "Panes", key: "-", symbol: "minus.magnifyingglass"),
        .init(id: "zoomReset", title: "Reset Terminal Font", group: "Panes", key: "0", symbol: "textformat.size"),
        .init(id: "shortcuts", title: "Keyboard Shortcuts", group: "Help", key: "/", modifiers: [.command, .shift], symbol: "keyboard")
    ]
    @MainActor var button: some View {
        Button(title) { CommandRouter.shared.run(id) }.keyboardShortcut(KeyEquivalent(Character(key)), modifiers: modifiers)
    }
}
private extension Dictionary where Key == String, Value == String {
    func defaulting(_ fallback: String, for key: String) -> String { self[key] ?? fallback }
}
extension Notification.Name { static let freemindCommand = Notification.Name("FreemindCommand") }

@MainActor
final class CommandRouter {
    static let shared = CommandRouter()
    var windows: [Int: UUID] = [:]
    private var monitor: Any?
    private var palette: NSPanel?
    var activeWindow: NSWindow? { NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow }
    var workspace: WorkspaceModel? {
        if let window = activeWindow, let id = windows[window.windowNumber] { return AppStore.shared.workspaces.first { $0.id == id } }
        return AppStore.shared.selected
    }
    func install() {
        guard monitor == nil else { return }
        // Close the focused panel before AppKit's standard Close Window item sees ⌘W.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.sheetParent == nil,
                  self?.palette == nil else { return event }
            self?.run("close"); return nil
        }
    }
    func run(_ id: String) {
        if id == "palette" || id == "shortcuts" || id == "quickOpen" { showPalette(files: id == "quickOpen"); return }
        let store = AppStore.shared
        if id == "open" { store.pickFolder(); return }
        if id == "closeWindow" { activeWindow?.performClose(nil); return }
        guard let workspace else { return }
        let focused = workspace.sessions.values.first { $0.view.window === activeWindow && $0.view.window?.firstResponder === $0.view }
        let paneID = focused?.pane.id ?? workspace.restoration.focusedPane
        switch id {
        case "newCodex": workspace.addPane()
        case "newShell": workspace.addPane(kind: .shell)
        case "splitRight": workspace.addPane(split: .horizontal)
        case "splitBelow": workspace.addPane(split: .vertical)
        case "nextPane": workspace.focusNext()
        case "previousPane": workspace.focusNext(direction: -1)
        case "maximize": if let paneID { workspace.maximize(paneID) }
        case "arrange": workspace.layout.automatic = true; workspace.restoration.maximizedPane = nil; workspace.saveSoon()
        case "code", "git", "notes": workspace.restoration.selectedTab = id.capitalized; workspace.saveSoon()
        case "files": workspace.restoration.selectedTab = "Code"; workspace.restoration.filesVisible.toggle(); workspace.saveSoon()
        case "save": _ = (workspace.restoration.selectedTab == "Notes" ? workspace.notesDocument : workspace.codeDocument).save()
        case "close":
            if workspace.restoration.selectedTab == "Code", focused == nil, workspace.restoration.selectedFile != nil {
                workspace.closeFile()
            } else if workspace.restoration.selectedTab == "Code", let paneID {
                let alert = NSAlert(); alert.messageText = "Close this terminal?"
                alert.informativeText = "Its running process will stop. Saved output stays in your workspace."
                alert.addButton(withTitle: "Close Terminal"); alert.addButton(withTitle: "Cancel")
                if let window = activeWindow { alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { workspace.closePane(paneID) } } }
            } else { activeWindow?.performClose(nil) }
        case "nextWorkspace", "previousWorkspace":
            guard !store.workspaces.isEmpty else { return }
            let index = store.workspaces.firstIndex(where: { $0.id == workspace.id }) ?? 0
            store.select(store.workspaces[(index + (id == "nextWorkspace" ? 1 : -1) + store.workspaces.count) % store.workspaces.count].id)
        case "zoomIn", "zoomOut", "zoomReset":
            if let paneID, let session = workspace.sessions[paneID] {
                let size = id == "zoomReset" ? 13 : max(9, min(28, session.view.font.pointSize + (id == "zoomIn" ? 1 : -1)))
                session.view.font = .monospacedSystemFont(ofSize: size, weight: .regular)
                try? DurableFile.save(Double(size), to: workspace.paths.terminal(paneID).appendingPathComponent("font.json"))
            }
        case "refreshGit": workspace.git.refreshSoon()
        default: notify(id, workspace: workspace)
        }
    }
    private func notify(_ id: String, workspace: WorkspaceModel) {
        NotificationCenter.default.post(name: .freemindCommand, object: workspace.id, userInfo: ["command": id, "window": activeWindow?.windowNumber ?? -1])
    }
    func showPalette(files: Bool) {
        if let palette { palette.makeKeyAndOrderFront(nil); return }
        guard let parent = activeWindow else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CommandPalette(workspace: workspace, files: files, selected: { [weak self, weak parent] item in
            self?.dismissPalette()
            parent?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { if let command = item.command { self?.run(command.id) } else if let path = item.file, let workspace = self?.workspace { workspace.restoration.selectedFile = workspace.paths.relative(path); workspace.restoration.filesVisible = true; workspace.restoration.selectedTab = "Code"; workspace.saveSoon() } }
        }, close: { [weak self] in self?.dismissPalette() }).appAppearance(store: AppStore.shared))
        palette = panel; parent.beginSheet(panel)
    }
    private func dismissPalette() { if let palette { palette.sheetParent?.endSheet(palette); palette.orderOut(nil) }; palette = nil }
}

struct PaletteItem: Identifiable {
    var command: AppCommand?
    var file: URL?
    var id: String { command?.id ?? file!.path }
    var title: String { command?.title ?? file!.lastPathComponent }
}
struct CommandPalette: View {
    @Environment(\.appTheme) private var theme
    let workspace: WorkspaceModel?
    let files: Bool
    let selected: (PaletteItem) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var fileResults: [URL] = []
    @State private var selection = 0
    var items: [PaletteItem] {
        if files { return fileResults.map { PaletteItem(file: $0) } }
        return AppCommand.all.filter { query.isEmpty || ($0.title + " " + $0.group).localizedCaseInsensitiveContains(query) }.map { PaletteItem(command: $0) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: files ? "doc.text.magnifyingglass" : "command").foregroundStyle(theme.accent)
                PaletteSearchField(text: $query, placeholder: files ? "Find a file in this workspace…" : "Search commands or keyboard shortcuts…", move: { offset in
                    selection = max(0, min(items.count - 1, selection + offset))
                }, submit: { if items.indices.contains(selection) { selected(items[selection]) } }, cancel: close)
                Button("esc", action: close).buttonStyle(.plain).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { selected(item) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.command?.symbol ?? "doc.text").frame(width: 18).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.system(size: 12))
                                        Text(item.command?.group ?? workspace?.paths.relative(item.file!) ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let hint = item.command?.hint { Text(hint).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4)) }
                                }.padding(.horizontal, 12).padding(.vertical, 9).background(selection == index ? theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).id(item.id)
                        }
                        if items.isEmpty { Text("No matches").foregroundStyle(.secondary).padding(32) }
                    }.padding(8)
                }.onChange(of: selection) { _, value in if items.indices.contains(value) { proxy.scrollTo(items[value].id) } }
            }
            Divider()
            HStack { Text("↑ ↓  Navigate     ↩  Run     esc  Close"); Spacer(); Text(files ? "⌘P" : "⌘K") }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(12)
        }.frame(width: 600, height: 460).background(.regularMaterial)
        .task { searchFiles() }
        .onChange(of: query) { _, _ in selection = 0; searchFiles() }
        .onKeyPress(.downArrow) { selection = min(items.count - 1, selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onExitCommand(perform: close)
    }
    func searchFiles() {
        guard files, let workspace else { return }; let search = query, root = workspace.paths.root
        Task { let entries = await Task.detached { FileListing.search(root, query: search, hidden: false) }.value; if query == search { fileResults = entries.map(\.url) } }
    }
}

struct FreemindCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(replacing: .newItem) { ForEach(AppCommand.all.filter { ["open", "newCodex", "newShell", "close", "closeWindow"].contains($0.id) }) { $0.button } }
        CommandGroup(replacing: .saveItem) { ForEach(AppCommand.all.filter { ["save", "comment"].contains($0.id) }) { $0.button } }
        CommandMenu("Navigate") { ForEach(AppCommand.all.filter { $0.group == "Navigate" }) { $0.button } }
        CommandMenu("Panes") { ForEach(AppCommand.all.filter { $0.group == "Panes" && !["newCodex", "newShell"].contains($0.id) }) { $0.button } }
        CommandMenu("Git") { ForEach(AppCommand.all.filter { $0.group == "Git" }) { $0.button } }
        CommandGroup(replacing: .help) { ForEach(AppCommand.all.filter { $0.group == "Help" }) { $0.button } }
        CommandGroup(before: .appTermination) {
            Button("Quit and Stop Terminals") { Task { await AppStore.shared.prepareToQuit(stop: true); NSApp.terminate(nil) } }
        }
    }
}

/// An AppKit field claims first responder after the sheet is attached to its window.
/// SwiftUI FocusState can run before an NSHostingView-backed sheet becomes key.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = FocusField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 15); field.textColor = .labelColor
        field.placeholderString = placeholder; field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class FocusField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey(); window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) { if let field = obj.object as? NSTextField { parent.text = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
