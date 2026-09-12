import AppKit
import SwiftUI
import SwiftTerm
import FreemindCore

final class FreemindTerminalView: LocalProcessTerminalView {
    var onScroll: ((Double) -> Void)?
    var diagnosticID = ""
    private(set) var appliedTheme: Theme?
    func applyTheme(_ theme: Theme) {
        guard appliedTheme != theme else { return }
        appliedTheme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        nativeBackgroundColor = theme.nativeCanvas
        nativeForegroundColor = theme.nativeText
        caretColor = theme.nativeAccent
        selectedTextBackgroundColor = theme.nativeSelection
        installColors(theme.ansiColors.map { SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) })
        needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        traceTerminal("resize \(diagnosticID) \(Int(newSize.width))x\(Int(newSize.height))")
        super.setFrameSize(newSize)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        insertFileURLs(urls)
        return true
    }
    func insertFileURLs(_ urls: [URL]) {
        window?.makeFirstResponder(self)
        let text = urls.map { ArgumentTokenizer.quote($0.path) }.joined(separator: " ") + " "
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { send(txt: "\u{1B}[200~") }; send(txt: text); if bracketed { send(txt: "\u{1B}[201~") }
    }
    override func scrolled(source: TerminalView, position: Double) { onScroll?(position) }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let pane: PaneDefinition
    let backend: TerminalBackend
    let paths: WorkspacePaths
    let view: FreemindTerminalView
    @Published var status = "Starting"
    @Published var running = false
    @Published var error: String?
    @Published var conversationID: String?
    @Published var recovered = false
    @Published private(set) var needsAttention = false
    var playAttentionSound: () -> Void = {
        if let sound = NSSound(named: NSSound.Name("Glass")) { sound.play() } else { NSSound.beep() }
    }
    var onFocus: (() -> Void)?
    var attached = false
    private var lastHookDate: Date?
    private var lastAttentionDate: Date?
    private var focusObserver: NSObjectProtocol?
    private var wasFocused = false
    init(pane: PaneDefinition, backend: TerminalBackend, paths: WorkspacePaths) {
        self.pane = pane; self.backend = backend; self.paths = paths
        view = FreemindTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        super.init()
        view.diagnosticID = pane.id.uuidString
        let fontSize = (try? DurableFile.load(Double.self, from: paths.terminal(pane.id).appendingPathComponent("font.json"))) ?? 13
        view.font = .monospacedSystemFont(ofSize: max(9, min(28, fontSize)), weight: .regular)
        view.processDelegate = self
        if pane.kind == .codex {
            view.bellStyle = .none
            view.getTerminal().registerOscHandler(code: 9) { [weak self] payload in
                // OSC 9;4 is terminal progress, not a desktop notification.
                guard !payload.isEmpty, !payload.starts(with: [52, 59]) else { return }
                self?.receiveAttention()
            }
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let focused = self.view.window?.firstResponder === self.view
                if focused && !self.wasFocused { self.onFocus?() }
                self.wasFocused = focused
            }
        }
        view.onScroll = { position in
            let url = paths.terminal(pane.id).appendingPathComponent("viewport.json")
            try? DurableFile.save(position, to: url)
        }
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    func start(initialPrompt: String? = nil) async {
        do {
            let existed = await backend.exists(pane.id)
            let old = try? Data(contentsOf: paths.terminal(pane.id).appendingPathComponent("screen.ansi"))
            recovered = !existed && old != nil
            try await backend.start(pane, initialPrompt: initialPrompt)
            if let old, let text = String(data: old, encoding: .utf8) { view.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n")) }
            let socket = await backend.socket, exe = await backend.executable, name = await backend.sessionName(pane.id)
            var env = await backend.environment; env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
            view.startProcess(executable: exe, args: ["-2", "-S", socket, "attach-session", "-t", name],
                              environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: paths.root.path)
            attached = true; running = true; status = recovered ? "Resumed" : "Ready"
            let position = (try? DurableFile.load(Double.self, from: paths.terminal(pane.id).appendingPathComponent("viewport.json"))) ?? 1
            if position < 0.99 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.view.scroll(toPosition: position) } }
        } catch { self.error = error.localizedDescription; status = "Could not start" }
    }
    func focus() { view.window?.makeFirstResponder(view) }
    func receive(_ event: HookEvent) {
        guard event.agentID == nil, lastHookDate == nil || event.timestamp > lastHookDate! else { return }
        lastHookDate = event.timestamp
        if let id = event.sessionID { conversationID = id }
        // Polling may deliver an older hook after the live terminal notification.
        guard lastAttentionDate == nil || event.timestamp > lastAttentionDate! else { return }
        status = event.status
        if event.event != "Stop" { needsAttention = false }
    }
    func receiveAttention() {
        guard pane.kind == .codex else { return }
        lastAttentionDate = Date()
        guard !needsAttention else { return }
        needsAttention = true
        if status != "Done" { status = "Needs attention" }
        playAttentionSound()
    }
    func disconnect() { if attached { view.terminate(); attached = false } }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { attached = false }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @Environment(\.terminalTheme) private var theme
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }
    func updateNSView(_ container: TerminalContainer, context: Context) {
        session.view.applyTheme(theme)
        container.mount(session.view)
    }
}

final class TerminalContainer: NSView {
    private weak var terminal: FreemindTerminalView?
    func mount(_ view: FreemindTerminalView) {
        guard view.superview !== self else { return }
        traceTerminal("mount \(view.diagnosticID)")
        terminal = view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        addSubview(view)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        // SwiftUI can propose zero bounds while inserting or moving a native
        // view. Never forward that temporary size to the PTY/TUI.
        if bounds.width > 1, bounds.height > 1, let terminal, terminal.frame != bounds {
            terminal.frame = bounds
        }
    }
}

private func traceTerminal(_ message: @autoclosure () -> String) {
    #if DEBUG
    if ProcessInfo.processInfo.environment["FREEMIND_TRACE_TERMINALS"] == "1" { NSLog("Freemind terminal: %@", message()) }
    #endif
}
