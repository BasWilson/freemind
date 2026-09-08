import Foundation

/// A portable text document with crash drafts and optimistic external-edit checks.
public struct WorkspaceDocument: Sendable {
    public private(set) var url: URL?
    public private(set) var text = ""
    public private(set) var baseline: Data?
    public var cursor = 0
    public var draftURL: URL?
    public var dirty: Bool { url != nil && Data(text.utf8) != baseline }
    public init(draftURL: URL? = nil) { self.draftURL = draftURL }

    private struct Draft: Codable { var path: String; var text: String; var baseline: Data?; var cursor: Int }
    public mutating func load(_ url: URL, force: Bool = false) throws {
        if self.url == url && !force { return }
        if dirty && !force { try save() }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 2 * 1024 * 1024 else {
            throw FreemindError.message("Choose a regular text file smaller than 2 MB. Larger files can be opened externally.")
        }
        let data = try Data(contentsOf: url)
        guard !data.prefix(8192).contains(0), let contents = String(data: data, encoding: .utf8) else {
            throw FreemindError.message("This file is binary or is not UTF-8. Open it externally.")
        }
        self.url = url; baseline = data; text = contents
        if !force, let draftURL, let draft = try? DurableFile.load(Draft.self, from: draftURL), draft.path == url.path {
            text = draft.text; baseline = draft.baseline; cursor = draft.cursor
        } else if force { try clearDraft() }
        cursor = max(0, min(cursor, text.unicodeScalars.count))
    }
    public mutating func change(_ text: String, cursor: Int? = nil) throws {
        guard let url else { return }
        self.text = text
        if let cursor { self.cursor = cursor }
        if dirty, let draftURL { try DurableFile.save(Draft(path: url.path, text: text, baseline: baseline, cursor: self.cursor), to: draftURL) }
        else { try clearDraft() }
    }
    public mutating func save() throws {
        guard dirty, let url else { return }
        try DurableFile.saveText(text, to: url, expected: baseline)
        baseline = Data(text.utf8); try clearDraft()
    }
    public func saveCopy(to output: URL) throws {
        try Data(text.utf8).write(to: output, options: .withoutOverwriting)
    }
    @discardableResult public mutating func externalChange() throws -> Bool {
        guard let url, (try? Data(contentsOf: url)) != baseline else { return false }
        guard !dirty else { throw FreemindError.message("This file changed on disk. Your edits are preserved. Save a copy or reload the disk version.") }
        try load(url, force: true); return true
    }
    private func clearDraft() throws {
        guard let draftURL else { return }
        for file in [draftURL, draftURL.appendingPathExtension("backup")] where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

public struct WorkspaceFileEntry: Equatable, Sendable {
    public var url: URL
    public var directory: Bool
}
public enum WorkspaceFileListing {
    public static func children(_ folder: URL, hidden: Bool) throws -> [WorkspaceFileEntry] {
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: hidden ? [] : [.skipsHiddenFiles])
        return entries.filter { $0.lastPathComponent != ".git" && !($0.lastPathComponent == "local" && folder.lastPathComponent == ".freemind") }.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return WorkspaceFileEntry(url: url, directory: values?.isDirectory == true && values?.isSymbolicLink != true)
        }.sorted { $0.directory != $1.directory ? $0.directory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
    public static func search(_ root: URL, query: String, hidden: Bool, limit: Int = 200) -> [WorkspaceFileEntry] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: hidden ? [] : [.skipsHiddenFiles]) else { return [] }
        var results: [WorkspaceFileEntry] = []
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                if values?.isSymbolicLink == true || [".git", "node_modules", ".build", ".build-support"].contains(url.lastPathComponent) || (url.lastPathComponent == "local" && url.deletingLastPathComponent().lastPathComponent == ".freemind") { files.skipDescendants() }
            } else if url.path.localizedCaseInsensitiveContains(query) {
                results.append(.init(url: url, directory: false))
                if results.count >= limit { break }
            }
        }
        return results
    }
}
