import SwiftUI
import AppKit
import FreemindCore

private struct EditorDraft: Codable {
    var path: String
    var text: String
    var baseline: Data?
    var cursor: Int
}
@MainActor
final class EditorDocument: ObservableObject {
    @Published var text = ""
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var error: String?
    @Published var dirty = false
    @Published var url: URL?
    var baseline: Data?
    var draftURL: URL?
    private var saving: Task<Void, Never>?
    var onSaved: (() -> Void)?
    func load(_ url: URL, force: Bool = false) {
        if self.url == url && !force { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw FreemindError.message("Select a regular text file.") }
            guard (values.fileSize ?? 0) <= 2 * 1024 * 1024 else { throw FreemindError.message("This file is larger than the 2 MB editor limit. Open it in an external editor.") }
            let data = try Data(contentsOf: url)
            guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { throw FreemindError.message("This file is binary or is not UTF-8 text. Open it in an external editor.") }
            self.url = url; baseline = data; self.text = text; dirty = false; error = nil
            if !force, let draftURL, let draft = try? DurableFile.load(EditorDraft.self, from: draftURL), draft.path == url.path {
                self.text = draft.text; baseline = draft.baseline; dirty = Data(draft.text.utf8) != data
                selection = NSRange(location: min(draft.cursor, (draft.text as NSString).length), length: 0)
                if draft.baseline != data { error = "Restored your unsaved edits. The file changed on disk; save a copy or reload." }
            } else {
                selection = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
                if force { clearDraft() }
            }
        } catch { self.url = url; text = ""; baseline = nil; dirty = false; self.error = error.localizedDescription }
    }
    func changed() {
        dirty = Data(text.utf8) != baseline
        if dirty, let draftURL, let url {
            do { try DurableFile.save(EditorDraft(path: url.path, text: text, baseline: baseline, cursor: selection.location), to: draftURL) }
            catch { self.error = "Could not checkpoint edits: " + error.localizedDescription }
        } else { clearDraft() }
    }
    private func clearDraft() {
        guard let draftURL else { return }
        try? FileManager.default.removeItem(at: draftURL)
        try? FileManager.default.removeItem(at: draftURL.appendingPathExtension("backup"))
    }
    func saveSoon() {
        changed(); saving?.cancel()
        saving = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { _ = save() } }
    }
    @discardableResult func save() -> Bool {
        saving?.cancel(); guard dirty, let url else { return true }
        do { try DurableFile.saveText(text, to: url, expected: baseline); baseline = Data(text.utf8); dirty = false; error = nil; clearDraft(); onSaved?(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func externalChange() {
        guard let url, let data = try? Data(contentsOf: url), data != baseline else { return }
        if dirty { error = "This file also changed on disk. Your edits are still here. Save a copy or reload the disk version." }
        else { load(url, force: true) }
    }
    func saveCopy() {
        guard let url else { return }
        let panel = NSSavePanel(); panel.directoryURL = url.deletingLastPathComponent(); panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-copy." + url.pathExtension
        if panel.runModal() == .OK, let output = panel.url {
            do { try Data(text.utf8).write(to: output, options: .atomic); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct NativeCodeEditor: NSViewRepresentable {
    @Environment(\.appTheme) private var theme
    @Binding var text: String
    @Binding var selection: NSRange
    var language = "txt"
    var lineNumbers = true
    var changed: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = lineNumbers; scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.minSize = NSSize(width: 0, height: 0); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = lineNumbers
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: lineNumbers ? 100_000 : 600, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = !lineNumbers
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false; view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.string = text; view.delegate = context.coordinator
        scroll.documentView = view
        if lineNumbers { scroll.verticalRulerView = LineNumbers(view: view, scroll: scroll); scroll.hasVerticalRuler = true; scroll.rulersVisible = true }
        context.coordinator.view = view
        context.coordinator.applyTheme(to: scroll)
        context.coordinator.highlight()
        let range = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        view.setSelectedRange(range); view.scrollRangeToVisible(range)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.applyTheme(to: scroll)
        if view.string != text {
            let selected = selection; context.coordinator.updating = true
            view.string = text; context.coordinator.highlight()
            view.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
            scroll.verticalRulerView?.needsDisplay = true; context.coordinator.updating = false
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        weak var view: NSTextView?
        var updating = false
        private var appliedTheme: Theme?
        private var highlightedLanguage: String?
        private var work: DispatchWorkItem?
        init(_ parent: NativeCodeEditor) { self.parent = parent }
        func applyTheme(to scroll: NSScrollView) {
            guard let view, appliedTheme != parent.theme || highlightedLanguage != parent.language else { return }
            appliedTheme = parent.theme; highlightedLanguage = parent.language
            scroll.backgroundColor = parent.theme.nativeCanvas
            view.backgroundColor = parent.theme.nativeCanvas
            view.textColor = parent.theme.nativeText
            view.insertionPointColor = parent.theme.nativeAccent
            view.selectedTextAttributes = [.backgroundColor: parent.theme.nativeSelection]
            view.typingAttributes[.foregroundColor] = parent.theme.nativeText
            if let ruler = scroll.verticalRulerView as? LineNumbers { ruler.theme = parent.theme; ruler.needsDisplay = true }
            highlight()
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view else { return }
            parent.text = view.string; parent.changed(); view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            work?.cancel(); let job = DispatchWorkItem { [weak self] in self?.highlight() }; work = job
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: job)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view else { return }; parent.selection = view.selectedRange()
        }
        func highlight() {
            guard let view, let storage = view.textStorage else { return }
            SyntaxColors.apply(storage, language: parent.language, theme: parent.theme)
        }
    }
}

final class LineNumbers: NSRulerView {
    var theme = Theme()
    weak var textView: NSTextView?
    private var observer: NSObjectProtocol?
    init(view: NSTextView, scroll: NSScrollView) {
        textView = view; super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = view; ruleThickness = 48
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.needsDisplay = true }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = textView, let manager = view.layoutManager, let container = view.textContainer else { return }
        theme.nativePanel.setFill(); bounds.fill()
        let string = view.string as NSString
        let glyphRange = manager.glyphRange(forBoundingRect: view.visibleRect, in: container)
        var glyph = glyphRange.location
        let firstChar = glyph < manager.numberOfGlyphs ? manager.characterIndexForGlyph(at: glyph) : 0
        var number = string.substring(to: min(firstChar, string.length)).components(separatedBy: "\n").count
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: theme.nativeMuted]
        while glyph < NSMaxRange(glyphRange), glyph < manager.numberOfGlyphs {
            var range = NSRange()
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let label = "\(number)" as NSString
            let point = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerInset.height), from: view)
            label.draw(at: NSPoint(x: ruleThickness - 10 - label.size(withAttributes: attributes).width, y: point.y), withAttributes: attributes)
            number += 1; glyph = NSMaxRange(range)
        }
    }
}

enum SyntaxColors {
    static let keywords = "\\b(?:func|let|var|struct|class|enum|protocol|extension|import|public|private|static|return|if|else|guard|switch|case|for|while|in|try|catch|throw|throws|async|await|actor|init|self|nil|true|false|def|from|as|with|pass|raise|lambda|None|True|False|function|const|export|default|new|this|interface|type|extends|implements|package|fn|pub|mut|impl|use|match|void|int|double|bool|String|Int|Double|Bool)\\b"
    static func apply(_ storage: NSTextStorage, language: String, theme: Theme) {
        let text = storage.string, range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: theme.nativeText, range: range)
        let rules: [(String, NSColor)] = [
            (keywords, theme.keyword),
            ("\\b\\d+(?:\\.\\d+)?\\b", theme.number),
            ("(?:\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`)", theme.string),
            ("(?m)//.*$|/\\*[\\s\\S]*?\\*/" + (["py", "sh", "rb", "toml", "yaml", "yml"].contains(language) ? "|(?m)#.*$" : ""), theme.nativeMuted)
        ]
        for (pattern, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
        }
        if language == "md", let regex = try? NSRegularExpression(pattern: "(?m)^#{1,6} .*$") {
            for match in regex.matches(in: text, range: range) { storage.addAttribute(.foregroundColor, value: theme.nativeAccent, range: match.range) }
        }
        storage.endEditing()
    }
}
