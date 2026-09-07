import Foundation
import CryptoKit

public struct TerminalSnapshot: Sendable {
    public var paneID: UUID
    public var running: Bool
    public var cwd: String
    public var pid: Int
    public var exitStatus: Int? = nil
    public var exitedSuccessfully: Bool { !running && exitStatus == 0 }
}
public struct LaunchRequest: Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    public var recoveryFile: String
    public var initialPrompt: String?
    public init(executable: String, arguments: [String], environment: [String: String], directory: String, recoveryFile: String, initialPrompt: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory
        self.recoveryFile = recoveryFile; self.initialPrompt = initialPrompt
    }
}

public enum TerminalPrompt {
    public static func url(recoveryFile: URL) -> URL { recoveryFile.deletingLastPathComponent().appendingPathComponent("initial-prompt.json") }
    public static func save(_ prompt: String, recoveryFile: URL) throws {
        let file = url(recoveryFile: recoveryFile)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(prompt).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func load(recoveryFile: URL) throws -> String? {
        let file = url(recoveryFile: recoveryFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // A malformed pending prompt must be reported, never silently dropped.
        return try JSONDecoder().decode(String.self, from: Data(contentsOf: file))
    }
    public static func remove(recoveryFile: URL) throws {
        let file = url(recoveryFile: recoveryFile)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

public actor TerminalBackend {
    public let paths: WorkspacePaths
    public let executable: String
    public let helper: String
    public let socket: String
    public let environment: [String: String]
    private let gate = OperationGate()
    public init(paths: WorkspacePaths, executable: String, helper: String, environment: [String: String]) {
        self.paths = paths; self.executable = executable; self.helper = helper; self.environment = Self.terminalEnvironment(environment)
        let hash = SHA256.hash(data: Data(paths.root.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        self.socket = "/tmp/freemind-\(getuid())/\(hash).sock"
    }
    public static func terminalEnvironment(_ inherited: [String: String]) -> [String: String] {
        var env = inherited
        env.removeValue(forKey: "NO_COLOR")
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["CLICOLOR"] = "1"; env["CLICOLOR_FORCE"] = "1"; env["FORCE_COLOR"] = "3"
        env["TERM_PROGRAM"] = "Freemind"; env["TERM_PROGRAM_VERSION"] = "0.1.0"
        return env
    }
    public func command(_ arguments: [String]) async throws -> CommandResult {
        try await CommandRunner.run(executable, ["-2", "-S", socket, "-f", paths.local.appendingPathComponent("tmux.conf").path] + arguments,
                                    cwd: paths.root, environment: environment)
    }
    public func sessionName(_ id: UUID) -> String { "fm-" + id.uuidString }
    public func exists(_ id: UUID) async -> Bool { (try? await command(["has-session", "-t", sessionName(id)]).code) == 0 }

    public func start(_ pane: PaneDefinition, initialPrompt: String? = nil) async throws {
        await gate.acquire()
        do {
            try await startLocked(pane, initialPrompt: initialPrompt)
            await gate.release()
        } catch { await gate.release(); throw error }
    }
    private func startLocked(_ pane: PaneDefinition, initialPrompt: String?) async throws {
        if await exists(pane.id) { try await observeExit(pane.id); return }
        let manager = FileManager.default
        let socketDir = URL(fileURLWithPath: socket).deletingLastPathComponent()
        try manager.createDirectory(at: socketDir, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDir.path)
        let conf = """
        set -g status off
        set -g prefix None
        set -g default-terminal xterm-256color
        set -as terminal-features ",xterm-256color:RGB"
        set -g history-limit 50000
        set -g mouse on
        set -g exit-unattached off
        set -g destroy-unattached off
        set -g focus-events on
        set -g escape-time 0
        set -g set-clipboard external
        set -g remain-on-exit on
        set -g allow-rename off
        set -g automatic-rename off
        """
        try Data(conf.utf8).write(to: paths.local.appendingPathComponent("tmux.conf"), options: .atomic)
        let terminal = paths.terminal(pane.id)
        try manager.createDirectory(at: terminal, withIntermediateDirectories: true)
        let recoveryURL = terminal.appendingPathComponent("recovery.json")
        let recovery = (try? DurableFile.load(PaneRecovery.self, from: recoveryURL)) ?? PaneRecovery()
        if !recovery.hasLaunched, let initialPrompt { try TerminalPrompt.save(initialPrompt, recoveryFile: recoveryURL) }
        let pendingPrompt = try TerminalPrompt.load(recoveryFile: recoveryURL)
        let directory = paths.resolve(recovery.hasLaunched ? recovery.workingDirectory : pane.directory)
        let cwd = manager.fileExists(atPath: directory.path) ? directory : paths.root
        var env = environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["FREEMIND_PANE_ID"] = pane.id.uuidString
        env["FREEMIND_EVENT_DIR"] = terminal.path
        let program: String
        var arguments: [String]
        if pane.kind == .codex {
            program = try Self.resolveCodex(pane.options.executable, environment: environment)
            let home = paths.codex(pane.id)
            try prepareCodexHome(home, options: pane.options)
            // Set Codex's documented child-process state root, never the host app's environment.
            env["CODEX_HOME"] = home.path
            env["CODEX_SQLITE_HOME"] = home.path
            arguments = try pane.options.arguments()
            if pane.options.automaticallyTrustWorkspace {
                var trustedPaths = Set([paths.root.path, cwd.path])
                if let result = try? await CommandRunner.run("/usr/bin/git", ["-C", cwd.path, "rev-parse", "--show-toplevel"], environment: environment), result.code == 0 {
                    trustedPaths.insert(result.output.trimmingCharacters(in: .newlines))
                }
                // CLI dotted keys are split literally, so paths containing dots or quotes
                // must be keys inside a TOML inline table value.
                let projects = trustedPaths.sorted().map { "\(CodexOptions.toml($0)) = { trust_level = \"trusted\" }" }.joined(separator: ", ")
                arguments += ["-c", "projects={\(projects)}"]
            }
            arguments += ["-C", cwd.path, "-c", "sqlite_home=\(CodexOptions.toml(home.path))", "-c", "log_dir=\(CodexOptions.toml(home.appendingPathComponent("logs").path))"]
            if manager.fileExists(atPath: home.appendingPathComponent("auth.json").path) { arguments += ["-c", "cli_auth_credentials_store=\"file\""] }
            if let id = recovery.conversationID { arguments = ["resume", id] + arguments }
        } else {
            program = environment["SHELL"] ?? "/bin/zsh"; arguments = ["-l"]
        }
        let request = LaunchRequest(executable: program, arguments: arguments, environment: env, directory: cwd.path,
                                    recoveryFile: recoveryURL.path, initialPrompt: pendingPrompt)
        let requestURL = terminal.appendingPathComponent("launch.json")
        try DurableFile.save(request, to: requestURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        // tmux accepts separate command argv; workspace text is never evaluated by a shell.
        _ = try await command(["new-session", "-d", "-s", sessionName(pane.id), "-x", "120", "-y", "30", "-c", cwd.path,
                               helper, "launch", requestURL.path]).checked()
        try await observeExit(pane.id)
    }
    private func observeExit(_ id: UUID) async throws {
        let signal = [helper, "pane-exited", paths.terminal(id).path].map(ArgumentTokenizer.quote).joined(separator: " ")
        _ = try await command(["set-hook", "-w", "-t", sessionName(id), "pane-died", "run-shell -b " + ArgumentTokenizer.quote(signal)]).checked()
        // Keep errors available for inspection; successful exits disappear from
        // the UI as soon as the event is observed, without tmux's dead-pane banner.
        _ = try await command(["set-option", "-w", "-t", sessionName(id), "remain-on-exit-format", ""]).checked()
    }
    private func prepareCodexHome(_ home: URL, options: CodexOptions) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let original = URL(fileURLWithPath: environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        // Share the credential file itself. Codex refreshes it via open/truncate, preserving the link.
        // Only configuration/resources are shared; mutable session/runtime storage stays local.
        for name in ["auth.json", "skills", "rules", "AGENTS.md", "themes"] {
            let target = original.appendingPathComponent(name), link = home.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: link.path) { try fm.createSymbolicLink(at: link, withDestinationURL: target) }
        }
        for url in (try? fm.contentsOfDirectory(at: original, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasSuffix(".config.toml") {
            let link = home.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: link.path) { try fm.createSymbolicLink(at: link, withDestinationURL: url) }
        }
        var config = (try? String(contentsOf: original.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        // The user's configuration is a local snapshot. App hooks live in a separate hooks.json.
        if options.hooks {
            let hooks = try HookConfiguration.make(helper: helper, home: home)
            try DurableFile.write(hooks.json, to: home.appendingPathComponent("hooks.json"))
            config += "\n" + hooks.trustTOML
        } else { try? fm.removeItem(at: home.appendingPathComponent("hooks.json")) }
        try Data(config.utf8).write(to: home.appendingPathComponent("config.toml"), options: .atomic)
    }
    public static func resolveCodex(_ explicit: String, environment: [String: String]) throws -> String {
        if !explicit.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: explicit) else { throw FreemindError.message("Codex is not executable at \(explicit). Choose its path in terminal settings.") }
            return explicit
        }
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(path) + "/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw FreemindError.message("Codex CLI was not found. Install it or choose its executable in terminal settings.")
    }
    public func stop(_ id: UUID) async throws { _ = try await command(["kill-session", "-t", sessionName(id)]).checked() }
    public func stopAll() async { _ = try? await command(["kill-server"]) }
    public func snapshot() async -> [TerminalSnapshot] {
        guard let result = try? await command(["list-panes", "-a", "-F", "#{session_name}\t#{pane_dead}\t#{pane_pid}\t#{pane_dead_status}\t#{pane_current_path}"]), result.code == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let id = UUID(uuidString: String(parts[0].dropFirst(3))) else { return nil }
            return TerminalSnapshot(paneID: id, running: parts[1] == "0", cwd: String(parts[4]), pid: Int(parts[2]) ?? 0, exitStatus: parts[1] == "1" ? Int(parts[3]) : nil)
        }
    }
    public func capture(_ id: UUID) async throws -> String {
        try await command(["capture-pane", "-p", "-e", "-S", "-50000", "-t", sessionName(id)]).checked().output
    }
    public func checkpoint(_ pane: PaneDefinition, running: TerminalSnapshot?) async throws -> PaneRecovery {
        let dir = paths.terminal(pane.id), url = dir.appendingPathComponent("recovery.json")
        var state = (try? DurableFile.load(PaneRecovery.self, from: url)) ?? .init()
        if let running, running.running, !running.cwd.isEmpty { state.workingDirectory = paths.relative(URL(fileURLWithPath: running.cwd)) }
        let session = try? DurableFile.load(HookEvent.self, from: dir.appendingPathComponent("session.json"))
        if let id = session?.sessionID { state.conversationID = id }
        if let event = try? DurableFile.load(HookEvent.self, from: dir.appendingPathComponent("event.json")),
           session?.sessionID == nil || event.sessionID == session?.sessionID {
            if let id = event.sessionID { state.conversationID = id }
            state.lastStatus = event.status
        }
        // SessionStart identifies this terminal's conversation, including /new and /fork.
        // Filesystem fallback is used only when this CLI has no session hooks.
        if pane.kind == .codex, session == nil, let id = Self.latestConversation(in: paths.codex(pane.id)) { state.conversationID = id }
        try DurableFile.save(state, to: url)
        if let capture = try? await capture(pane.id) { try Data(capture.utf8).write(to: dir.appendingPathComponent("screen.ansi"), options: .atomic) }
        return state
    }
    public static func latestConversation(in home: URL) -> String? {
        let roots = [home.appendingPathComponent("sessions"), home.appendingPathComponent("threads")]
        var latest: (Date, String)?
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                let name = file.deletingPathExtension().lastPathComponent
                guard name.count >= 36 else { continue }
                let id = String(name.suffix(36))
                guard UUID(uuidString: id) != nil else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if latest == nil || date > latest!.0 { latest = (date, id) }
            }
        }
        return latest?.1
    }
}
