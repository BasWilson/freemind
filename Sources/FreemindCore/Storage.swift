import Foundation

public enum DurableFile {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e
    }()
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch {
            let backup = url.appendingPathExtension("backup")
            if let data = try? Data(contentsOf: backup), let value = try? JSONDecoder().decode(type, from: data) { return value }
            throw error
        }
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try write(data, to: url)
    }
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? Data(contentsOf: url), current == data { return }
        if let old = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: old)) != nil {
            try old.write(to: url.appendingPathExtension("backup"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
    /// Optimistic concurrency for notes/code: never silently replace external edits.
    public static func saveText(_ text: String, to url: URL, expected: Data?) throws {
        let current = try? Data(contentsOf: url)
        guard current == expected else { throw FreemindError.message("\(url.lastPathComponent) changed on disk. Reload it, or save your edits as a separate file.") }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

public struct WorkspacePaths: Sendable {
    public let root: URL
    public var metadata: URL { root.appendingPathComponent(".freemind", isDirectory: true) }
    public var local: URL { metadata.appendingPathComponent("local", isDirectory: true) }
    public var notes: URL { metadata.appendingPathComponent("notes", isDirectory: true) }
    public var definition: URL { metadata.appendingPathComponent("workspace.json") }
    public var layout: URL { metadata.appendingPathComponent("layout.json") }
    public var restoration: URL { local.appendingPathComponent("restoration.json") }
    public var comments: URL { metadata.appendingPathComponent("comments.json") }
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    public func terminal(_ id: UUID) -> URL { local.appendingPathComponent("terminals/\(id.uuidString)", isDirectory: true) }
    public func codex(_ id: UUID) -> URL { local.appendingPathComponent("codex/\(id.uuidString)", isDirectory: true) }
    public func relative(_ url: URL) -> String {
        let base = root.path + "/", path = url.standardizedFileURL.path
        if path == root.path { return "." }
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
    public func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
    }
    public func initialize(defaults: CodexOptions = .init()) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw FreemindError.message("The workspace folder is missing: \(root.path)") }
        for dir in [metadata, local, notes, metadata.appendingPathComponent("history")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
        let ignore = metadata.appendingPathComponent(".gitignore")
        let required = ["/local/", "*.backup", ".DS_Store"]
        var contents = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        for line in required where !contents.components(separatedBy: .newlines).contains(line) { contents += (contents.hasSuffix("\n") || contents.isEmpty ? "" : "\n") + line + "\n" }
        try Data(contents.utf8).write(to: ignore, options: .atomic)
        if !FileManager.default.fileExists(atPath: definition.path) {
            var workspace = WorkspaceDefinition(name: root.lastPathComponent)
            workspace.defaults = defaults
            try DurableFile.save(workspace, to: definition)
        }
        if !FileManager.default.fileExists(atPath: layout.path) { try DurableFile.save(WorkspaceLayout(), to: layout) }
        let note = notes.appendingPathComponent("Notes.md")
        if !FileManager.default.fileExists(atPath: note.path) { try Data("# Workspace notes\n\n".utf8).write(to: note) }
        let loaded = try DurableFile.load(WorkspaceDefinition.self, from: definition)
        guard loaded.schemaVersion == 1 else { throw FreemindError.message("This workspace uses a newer file format. Update Freemind before opening it.") }
    }
}

public struct HookEvent: Codable, Equatable, Sendable {
    public var event: String
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    public var timestamp: Date
    public var agentID: String? = nil
    public var status: String {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return "Working"
        case "PermissionRequest": return "Working"
        case "Stop": return "Done"
        case "Interrupt": return "Interrupted"
        case "SessionEnd": return "Ended"
        case "PreCompact": return "Compacting"
        default: return "Ready"
        }
    }
    public static func parse(_ data: Data) throws -> HookEvent {
        guard data.count <= 8 * 1024 * 1024,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["hook_event_name"] as? String else { throw FreemindError.message("Invalid hook event") }
        let raw = obj["session_id"] as? String
        let id = raw.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        return HookEvent(event: event, sessionID: id, cwd: obj["cwd"] as? String, model: obj["model"] as? String, timestamp: Date(), agentID: obj["agent_id"] as? String)
    }
}
