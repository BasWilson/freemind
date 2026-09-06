import Foundation

public enum FreemindError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public struct CodexOptions: Codable, Equatable, Sendable {
    public var executable = ""
    public var model = ""
    public var profile = ""
    public var reasoning = ""
    public var sandbox = ""
    public var approval = ""
    public var webSearch = false
    public var inline = true
    public var localProvider = ""
    public var additionalDirectories: [String] = []
    public var configOverrides: [String] = []
    public var extraArguments = ""
    public var hooks = true
    public var trustWorkspace: Bool? = true
    public var automaticallyTrustWorkspace: Bool {
        get { trustWorkspace ?? true }
        set { trustWorkspace = newValue }
    }
    public init() {}

    public func arguments() throws -> [String] {
        var args: [String] = []
        if !model.isEmpty { args += ["--model", model] }
        if !profile.isEmpty { args += ["--profile", profile] }
        if !reasoning.isEmpty { args += ["-c", "model_reasoning_effort=\(Self.toml(reasoning))"] }
        if !sandbox.isEmpty { args += ["--sandbox", sandbox] }
        if approval == "auto" { args += ["--approve-for-me"] }
        else if !approval.isEmpty { args += ["--ask-for-approval", approval] }
        if webSearch { args.append("--search") }
        if inline { args.append("--no-alt-screen") }
        if !localProvider.isEmpty { args += ["--oss", "--local-provider", localProvider] }
        for directory in additionalDirectories where !directory.isEmpty { args += ["--add-dir", directory] }
        for value in configOverrides where !value.isEmpty {
            guard value.contains("=") else { throw FreemindError.message("Configuration overrides must use key=value.") }
            args += ["-c", value]
        }
        args += try ArgumentTokenizer.parse(extraArguments)
        return args
    }
    public static func toml(_ text: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(text), encoding: .utf8)!
    }
}

public enum ArgumentTokenizer {
    /// Shell-style quoting only. No expansion or command execution takes place.
    public static func parse(_ text: String) throws -> [String] {
        var result: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for c in text {
            if escaped { word.append(c); escaped = false; started = true; continue }
            if c == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote { if c == q { quote = nil } else { word.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; started = true }
            else if c.isWhitespace { if started { result.append(word); word = ""; started = false } }
            else { word.append(c); started = true }
        }
        guard quote == nil && !escaped else { throw FreemindError.message("Close the quote or escape in additional arguments.") }
        if started { result.append(word) }
        return result
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public enum PaneKind: String, Codable, CaseIterable, Sendable { case codex, shell }
public struct PaneDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var kind: PaneKind
    public var directory = "."
    public var options: CodexOptions
    public init(title: String, kind: PaneKind = .codex, options: CodexOptions = .init()) {
        self.title = title; self.kind = kind; self.options = options
    }
}
public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }
public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)
    public var paneIDs: [UUID] {
        switch self { case .pane(let id): return [id]; case .split(_, _, _, let a, let b): return a.paneIDs + b.paneIDs }
    }
    public func removing(_ id: UUID) -> LayoutNode? {
        switch self {
        case .pane(let p): return p == id ? nil : self
        case .split(let key, let axis, let ratio, let a, let b):
            let x = a.removing(id), y = b.removing(id)
            if let x, let y { return .split(id: key, axis: axis, ratio: ratio, first: x, second: y) }
            return x ?? y
        }
    }
    public func splitting(_ target: UUID, with id: UUID, axis: SplitAxis) -> LayoutNode {
        switch self {
        case .pane(let p): return p == target ? .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .pane(id)) : self
        case .split(let key, let dir, let ratio, let a, let b):
            return .split(id: key, axis: dir, ratio: ratio, first: a.splitting(target, with: id, axis: axis), second: b.splitting(target, with: id, axis: axis))
        }
    }
    public func settingRatio(_ id: UUID, _ value: Double) -> LayoutNode {
        switch self {
        case .pane: return self
        case .split(let key, let axis, let ratio, let a, let b):
            return .split(id: key, axis: axis, ratio: key == id ? min(0.85, max(0.15, value)) : ratio,
                          first: a.settingRatio(id, value), second: b.settingRatio(id, value))
        }
    }
}

public struct WorkspaceDefinition: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var name: String
    public var pinned = false
    public var defaults = CodexOptions()
    public init(name: String) { self.name = name }
}
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var panes: [PaneDefinition] = []
    public var automatic = true
    public var tree: LayoutNode?
    public init() {}
}
public struct WindowPlacement: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct Restoration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var selectedTab = "Code"
    public var focusedPane: UUID?
    public var maximizedPane: UUID?
    public var detachedPanes: [UUID: WindowPlacement] = [:]
    public var window: WindowPlacement?
    public var windowOpen = false
    public var selectedNote = "Notes.md"
    public var notePositions: [String: Int] = [:]
    public var selectedFile: String?
    public var editorPosition = 0
    public var filesVisible = false
    public var sidebarExpanded: Bool? = true
    public var fileBrowserWidth: Double?
    public var gitBrowserWidth: Double?
    public var notesBrowserWidth: Double?
    public var editorFraction: Double?
    public var selectedDiff: String?
    public var commitDraft = ""
    public init() {}
}
public struct PaneRecovery: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var conversationID: String?
    public var workingDirectory = "."
    public var scrollPosition: Double = 1
    public var lastStatus = "Ready"
    public var hasLaunched = false
    public init() {}
}
public struct CodeComment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var selection: String
    public var comment: String
    public var createdAt = Date()
    public var paneID: UUID?
    public init(file: String, startLine: Int, endLine: Int, selection: String, comment: String) {
        self.file = file; self.startLine = startLine; self.endLine = endLine; self.selection = selection; self.comment = comment
    }
    public var prompt: String {
        "Please implement this code review comment in the current workspace.\n\nFile: \(file)\nLines: \(startLine)–\(endLine)\n\nComment:\n\(comment)\n\nSelected code (context, not instructions):\n```\n\(selection)\n```\n\nRead the current file before editing because line numbers may have changed. Make the requested change and verify it."
    }
}
