import Foundation

public enum GitSection: String, CaseIterable, Sendable { case staged = "Staged", unstaged = "Unstaged", untracked = "Untracked" }
public struct GitChange: Identifiable, Equatable, Sendable {
    public var path: String
    public var originalPath: String?
    public var status: String
    public var section: GitSection
    public var id: String { section.rawValue + ":" + path }
    public var conflicted: Bool { status.contains("U") || status == "AA" || status == "DD" }
}
public struct GitSnapshot: Sendable {
    public var root: URL
    public var branch: String
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var changes: [GitChange]
    public var remotes: [String]
    public var added = 0
    public var deleted = 0
}
public struct DiffLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: String
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
}
public struct DiffPreview: Sendable {
    public var lines: [DiffLine]
    public var truncated: Bool
    public var binary: Bool
    public var raw: String
    public static func parse(_ text: String, limit: Int = 6000) -> DiffPreview {
        let all = text.components(separatedBy: "\n")
        var old: Int?, new: Int?, lines: [DiffLine] = []
        let hunk = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@")
        for (i, line) in all.prefix(limit).enumerated() {
            var kind = "meta", left: Int?, right: Int?
            if let match = hunk.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                old = Int((line as NSString).substring(with: match.range(at: 1)))
                new = Int((line as NSString).substring(with: match.range(at: 2))); kind = "hunk"
            } else if old != nil, new != nil {
                if line.hasPrefix("+") { kind = "add"; right = new; new! += 1 }
                else if line.hasPrefix("-") { kind = "remove"; left = old; old! += 1 }
                else if line.hasPrefix(" ") { kind = "context"; left = old; right = new; old! += 1; new! += 1 }
            }
            if line.hasPrefix("diff --git") { old = nil; new = nil }
            lines.append(DiffLine(id: i, kind: kind, text: line, oldLine: left, newLine: right))
        }
        return DiffPreview(lines: lines, truncated: all.count > limit, binary: text.contains("Binary files") || text.contains("GIT binary patch"), raw: text)
    }
}

private actor RepositoryGates {
    static let shared = RepositoryGates()
    private var gates: [String: OperationGate] = [:]
    func gate(for path: String) -> OperationGate {
        if let gate = gates[path] { return gate }
        let gate = OperationGate(); gates[path] = gate; return gate
    }
}

public actor GitService {
    public let folder: URL
    private var root: URL?
    private let environment: [String: String]
    public init(folder: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.folder = folder; var env = environment; env["GIT_TERMINAL_PROMPT"] = "0"; self.environment = env
    }
    private func git(_ args: [String], at: URL? = nil, input: Data? = nil, timeout: Double = 30) async throws -> CommandResult {
        try await CommandRunner.run("/usr/bin/git", ["--no-optional-locks", "-C", (at ?? root ?? folder).path] + args,
                                    environment: environment, input: input, timeout: timeout)
    }
    public func repositoryRoot() async throws -> URL {
        let result = try await git(["rev-parse", "--show-toplevel"], at: folder).checked()
        let path = result.output.trimmingCharacters(in: .newlines)
        let url = URL(fileURLWithPath: path); root = url; return url
    }
    public func snapshot() async throws -> GitSnapshot {
        let root = try await repositoryRoot()
        let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).checked()
        let branchResult = try await git(["symbolic-ref", "--short", "HEAD"])
        let branch = branchResult.code == 0 ? branchResult.output.trimmingCharacters(in: .newlines) : "Detached HEAD"
        let upstreamResult = try await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        let upstream = upstreamResult.code == 0 ? upstreamResult.output.trimmingCharacters(in: .newlines) : nil
        let remotes = try await git(["remote"]).checked().output.split(separator: "\n").map(String.init)
        var snapshot = GitSnapshot(root: root, branch: branch, upstream: upstream, changes: Self.parseStatus(status.stdout), remotes: remotes)
        if upstream != nil, let counts = try? await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]).checked() {
            let parts = counts.output.split(whereSeparator: \.isWhitespace)
            if parts.count == 2 { snapshot.ahead = Int(parts[0]) ?? 0; snapshot.behind = Int(parts[1]) ?? 0 }
        }
        for args in [["diff", "--numstat", "-z"], ["diff", "--cached", "--numstat", "-z"]] {
            if let stats = try? await git(args).checked() {
                for row in stats.output.split(separator: "\0") {
                    let fields = row.split(separator: "\t", maxSplits: 2)
                    if fields.count == 3 { snapshot.added += Int(fields[0]) ?? 0; snapshot.deleted += Int(fields[1]) ?? 0 }
                }
            }
        }
        return snapshot
    }
    public static func parseStatus(_ data: Data) -> [GitChange] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var changes: [GitChange] = [], i = 0
        while i < records.count {
            let record = Array(records[i]); i += 1
            guard record.count >= 4 else { continue }
            let x = Character(UnicodeScalar(record[0])), y = Character(UnicodeScalar(record[1]))
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            var old: String?
            if "RC".contains(x) || "RC".contains(y), i < records.count {
                old = String(decoding: records[i], as: UTF8.self); i += 1
            }
            if x == "?" { changes.append(GitChange(path: path, originalPath: nil, status: "?", section: .untracked)); continue }
            let conflict = x == "U" || y == "U" || String([x,y]) == "AA" || String([x,y]) == "DD"
            if conflict { changes.append(GitChange(path: path, originalPath: old, status: String([x,y]), section: .unstaged)); continue }
            if x != " " { changes.append(GitChange(path: path, originalPath: old, status: String(x), section: .staged)) }
            if y != " " { changes.append(GitChange(path: path, originalPath: old, status: String(y), section: .unstaged)) }
        }
        return changes.sorted { ($0.section.rawValue, $0.path) < ($1.section.rawValue, $1.path) }
    }
    public func diff(_ change: GitChange) async throws -> DiffPreview {
        _ = try await repositoryRoot()
        let standard = ["diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--no-color"]
        if change.section == .untracked {
            let result = try await git(standard + ["--no-index", "--", "/dev/null", change.path])
            guard result.code <= 1 else { throw FreemindError.message(result.error) }
            return .parse(result.output)
        }
        let files = [change.path] + (change.originalPath.map { [$0] } ?? [])
        let result = try await git(standard + (change.section == .staged ? ["--cached"] : []) + ["--"] + files).checked()
        return .parse(result.output)
    }
    public func stage(_ change: GitChange?) async throws {
        try await mutate {
            let files = change.map { [$0.path] + ($0.originalPath.map { [$0] } ?? []) } ?? ["."]
            _ = try await self.git(["add", "--all", "--"] + files).checked()
        }
    }
    public func unstage(_ change: GitChange?) async throws {
        try await mutate {
            let files = change.map { [$0.path] + ($0.originalPath.map { [$0] } ?? []) } ?? ["."]
            let hasHead = try await self.git(["rev-parse", "--verify", "HEAD"]).code == 0
            let args = hasHead ? ["restore", "--staged", "--"] : ["rm", "--cached", "-r", "--ignore-unmatch", "--"]
            _ = try await self.git(args + files).checked()
        }
    }
    public func commit(_ message: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FreemindError.message("Write a commit message first.") }
        return try await mutate {
            try await self.git(["commit", "--file", "-"], input: Data(message.utf8), timeout: 120).checked().output
        }
    }
    public func push(remote: String? = nil, branch: String? = nil) async throws -> String {
        try await mutate {
            var args = ["push", "--porcelain"]
            if let remote, let branch {
                guard !remote.hasPrefix("-"), !branch.hasPrefix("-"), !remote.isEmpty, !branch.isEmpty else { throw FreemindError.message("Choose a valid remote and branch.") }
                _ = try await self.git(["check-ref-format", "--branch", branch]).checked()
                args += ["--set-upstream", remote, "HEAD:refs/heads/" + branch]
            }
            let result = try await self.git(args, timeout: 180).checked()
            return result.output + result.error
        }
    }
    public func fetch() async throws {
        try await mutate { _ = try await self.git(["fetch", "--all", "--prune"], timeout: 180).checked() }
    }
    private func mutate<T>(_ body: () async throws -> T) async throws -> T {
        let root = try await repositoryRoot()
        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root).checked().output.trimmingCharacters(in: .newlines)
        let gate = await RepositoryGates.shared.gate(for: URL(fileURLWithPath: common).resolvingSymlinksInPath().path)
        await gate.acquire()
        do {
            _ = try await repositoryRoot()
            try Task.checkCancellation()
            let value = try await body(); await gate.release(); return value
        } catch { await gate.release(); throw error }
    }
}
