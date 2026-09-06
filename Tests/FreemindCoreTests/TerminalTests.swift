import XCTest
@testable import FreemindCore

final class TerminalTests: XCTestCase {
    func testExitEventDistinguishesSuccessFailureAndSurvivingSessions() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind exit 'test " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = WorkspacePaths(root: root); try paths.initialize()
        var env = ProcessInfo.processInfo.environment; env["SHELL"] = "/bin/sh"
        let backend = TerminalBackend(paths: paths, executable: repo.appendingPathComponent("Resources/bin/tmux").path,
                                      helper: repo.appendingPathComponent(".build/debug/freemind-helper").path, environment: env)
        let success = PaneDefinition(title: "Normal exit", kind: .shell)
        let failed = PaneDefinition(title: "Failed exit", kind: .shell)
        let survivor = PaneDefinition(title: "Still running", kind: .shell)
        do {
            for pane in [success, failed, survivor] { try await backend.start(pane) }
            // Also install the exit observer when adopting an existing session.
            try await backend.start(success)
            for (pane, code) in [(success, 0), (failed, 7)] {
                let name = await backend.sessionName(pane.id)
                _ = try await backend.command(["send-keys", "-t", name, "-l", "printf EXIT_TEST_OUTPUT; exit \(code)"]).checked()
                _ = try await backend.command(["send-keys", "-t", name, "Enter"]).checked()
            }
            let signal = paths.terminal(success.id).appendingPathComponent("exit-event.json")
            let failureSignal = paths.terminal(failed.id).appendingPathComponent("exit-event.json")
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: signal.path), FileManager.default.fileExists(atPath: failureSignal.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: signal.path), "Exit hook must wake the UI, including paths with spaces and quotes")
            XCTAssertTrue(FileManager.default.fileExists(atPath: failureSignal.path))
            let snapshots = await backend.snapshot()
            let normal = try XCTUnwrap(snapshots.first { $0.paneID == success.id })
            let failure = try XCTUnwrap(snapshots.first { $0.paneID == failed.id })
            let live = try XCTUnwrap(snapshots.first { $0.paneID == survivor.id })
            XCTAssertTrue(normal.exitedSuccessfully)
            XCTAssertFalse(failure.exitedSuccessfully); XCTAssertEqual(failure.exitStatus, 7)
            XCTAssertFalse(live.exitedSuccessfully); XCTAssertTrue(live.running); XCTAssertNil(live.exitStatus)
            let output = try await backend.capture(success.id)
            XCTAssertTrue(output.contains("EXIT_TEST_OUTPUT")); XCTAssertFalse(output.contains("Pane is dead"))
            _ = try await backend.checkpoint(success, running: normal)
            try await backend.stop(success.id)
            let remaining = await backend.snapshot()
            XCTAssertEqual(Set(remaining.map(\.paneID)), [failed.id, survivor.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.terminal(success.id).appendingPathComponent("screen.ansi").path))
            await backend.stopAll()
            try FileManager.default.removeItem(at: root)
        } catch { await backend.stopAll(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func testSessionSurvivesClientsAndRecoversDirectoryAfterServerLoss() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let paths = WorkspacePaths(root: root); try paths.initialize()
        var env = ProcessInfo.processInfo.environment; env["SHELL"] = "/bin/sh"
        let backend = TerminalBackend(paths: paths, executable: repo.appendingPathComponent("Resources/bin/tmux").path,
                                      helper: repo.appendingPathComponent(".build/debug/freemind-helper").path, environment: env)
        let pane = PaneDefinition(title: "Persistent shell", kind: .shell)
        do {
            try await backend.start(pane)
            let name = await backend.sessionName(pane.id)
            _ = try await backend.command(["send-keys", "-t", name, "-l", "cd nested; export FREEMIND_TEST_VALUE=alive; printf 'FREEMIND_READY_🙂\\n'; touch .freemind-ready"]).checked()
            _ = try await backend.command(["send-keys", "-t", name, "Enter"]).checked()
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("nested/.freemind-ready").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let firstSnapshots = await backend.snapshot()
            let first = try XCTUnwrap(firstSnapshots.first { $0.paneID == pane.id })
            XCTAssertTrue(first.running)
            let output = try await backend.capture(pane.id); XCTAssertTrue(output.contains("FREEMIND_READY_🙂"))
            let recovery = try await backend.checkpoint(pane, running: first)
            XCTAssertEqual(recovery.workingDirectory, "nested", "cwd=\(first.cwd); output=\(output)")
            // A new frontend instance must adopt the existing server/session instead of relaunching.
            let reopened = TerminalBackend(paths: paths, executable: repo.appendingPathComponent("Resources/bin/tmux").path,
                                           helper: repo.appendingPathComponent(".build/debug/freemind-helper").path, environment: env)
            try await reopened.start(pane)
            let secondSnapshots = await reopened.snapshot()
            let second = try XCTUnwrap(secondSnapshots.first { $0.paneID == pane.id })
            XCTAssertEqual(first.pid, second.pid)
            _ = try await reopened.command(["send-keys", "-t", name, "-l", "printf 'STATE_%s\\n' \"$FREEMIND_TEST_VALUE\""]).checked()
            _ = try await reopened.command(["send-keys", "-t", name, "Enter"]).checked()
            try await Task.sleep(for: .milliseconds(150))
            let preserved = try await reopened.capture(pane.id); XCTAssertTrue(preserved.contains("STATE_alive"))
            await backend.stopAll()
            try await Task.sleep(for: .milliseconds(150))
            try await reopened.start(pane)
            try await Task.sleep(for: .milliseconds(150))
            let restoredSnapshots = await reopened.snapshot()
            let restored = try XCTUnwrap(restoredSnapshots.first { $0.paneID == pane.id })
            XCTAssertTrue(restored.cwd.hasSuffix("/nested")); XCTAssertNotEqual(restored.pid, first.pid)
            for index in 0..<16 { try await reopened.start(PaneDefinition(title: "Shell \(index)", kind: .shell)) }
            let snapshots = await reopened.snapshot(); XCTAssertEqual(snapshots.count, 17)
            await reopened.stopAll()
            try FileManager.default.removeItem(at: root)
        } catch { await backend.stopAll(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func testTerminalColorEnvironmentOverridesNoninteractiveLauncher() {
        let env = TerminalBackend.terminalEnvironment(["NO_COLOR": "1", "TERM": "dumb", "CLICOLOR": "0", "PATH": "/bin"])
        XCTAssertNil(env["NO_COLOR"])
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["FORCE_COLOR"], "3")
        XCTAssertEqual(env["PATH"], "/bin")
    }
    func testDeadPaneCannotOverwriteWorkingDirectoryOrHookIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkspacePaths(root: root); try paths.initialize()
        let pane = PaneDefinition(title: "Codex")
        let backend = TerminalBackend(paths: paths, executable: "/usr/bin/false", helper: "/usr/bin/false", environment: [:])
        let primary = UUID().uuidString, secondary = UUID().uuidString
        let event = try HookEvent.parse(Data("{\"hook_event_name\":\"SessionStart\",\"session_id\":\"\(primary)\"}".utf8))
        try DurableFile.save(event, to: paths.terminal(pane.id).appendingPathComponent("session.json"))
        let files = paths.codex(pane.id).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: files.appendingPathComponent("rollout-\(secondary).jsonl"))
        var saved = PaneRecovery(); saved.workingDirectory = "nested"; saved.hasLaunched = true
        try DurableFile.save(saved, to: paths.terminal(pane.id).appendingPathComponent("recovery.json"))
        let restored = try await backend.checkpoint(pane, running: TerminalSnapshot(paneID: pane.id, running: false, cwd: "/", pid: 123))
        XCTAssertEqual(restored.workingDirectory, "nested")
        XCTAssertEqual(restored.conversationID, primary)
    }
    func testOptionsAndHookTrustAreScoped() throws {
        var options = CodexOptions(); options.model = "test-model"; options.profile = "review"; options.webSearch = true
        options.sandbox = "workspace-write"; options.approval = "on-request"; options.additionalDirectories = ["a b"]
        options.configOverrides = ["model_reasoning_effort=\"high\""]
        let args = try options.arguments()
        XCTAssertTrue(args.contains("--search")); XCTAssertTrue(args.contains("a b")); XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        let hooks = try HookConfiguration.make(helper: "/Applications/Freemind Test.app/helper", home: URL(fileURLWithPath: "/tmp/pane-home"))
        XCTAssertTrue(hooks.trustTOML.contains("/tmp/pane-home/hooks.json:session_start:0:0"))
        XCTAssertFalse(hooks.trustTOML.contains("bypass"))
    }
}

extension TerminalTests {
    func testLiveInstalledCodexColorTrustAndConversationResume() async throws {
        guard ProcessInfo.processInfo.environment["FREEMIND_LIVE_CODEX"] == "1" else { throw XCTSkip("Opt-in integration with the user's installed Codex") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = WorkspacePaths(root: root); try paths.initialize()
        var env = ProcessInfo.processInfo.environment
        let shell = try await CommandRunner.run("/bin/zsh", ["-lic", "/usr/bin/env -0"]).checked()
        for pair in shell.output.split(separator: "\0") {
            guard let index = pair.firstIndex(of: "=") else { continue }
            env[String(pair[..<index])] = String(pair[pair.index(after: index)...])
        }
        let backend = TerminalBackend(paths: paths, executable: repo.appendingPathComponent("Resources/bin/tmux").path,
                                      helper: repo.appendingPathComponent("dist/Freemind.app/Contents/MacOS/freemind-helper").path, environment: env)
        var options = CodexOptions(); options.reasoning = "low"
        let pane = PaneDefinition(title: "Live integration", options: options)
        do {
            try await backend.start(pane)
            var state = PaneRecovery(), output = ""
            for _ in 0..<80 {
                try await Task.sleep(for: .milliseconds(250))
                let snapshots = await backend.snapshot()
                state = try await backend.checkpoint(pane, running: snapshots.first)
                output = (try? await backend.capture(pane.id)) ?? ""
                if output.contains("Tip:") || output.contains("Hooks need review") { break }
            }
            XCTAssertFalse(output.contains("Do you trust the contents"))
            XCTAssertFalse(output.contains("Error loading config"))
            XCTAssertTrue(output.contains("\u{1B}["), "Codex must emit ANSI styling")
            XCTAssertFalse(output.contains("Hooks need review"))
            let name = await backend.sessionName(pane.id)
            _ = try await backend.command(["send-keys", "-t", name, "-l", "Reply exactly FREEMIND_LIVE_READY. Do not use tools or edit files."]).checked()
            // Codex groups rapid keyboard bursts as pasted text. Submit after that burst settles.
            try await Task.sleep(for: .milliseconds(800))
            _ = try await backend.command(["send-keys", "-t", name, "Enter"]).checked()
            var completed = false
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(500))
                if let event = try? DurableFile.load(HookEvent.self, from: paths.terminal(pane.id).appendingPathComponent("event.json")), event.event == "Stop" { completed = true; break }
            }
            output = try await backend.capture(pane.id)
            XCTAssertTrue(completed, "The CLI should finish a response using existing authentication. Screen: \(output.suffix(6000))")
            let snapshots = await backend.snapshot()
            state = try await backend.checkpoint(pane, running: snapshots.first)
            let identity = try XCTUnwrap(state.conversationID, "SessionStart is emitted on the first turn")
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.terminal(pane.id).appendingPathComponent("session.json").path))
            output = try await backend.capture(pane.id)
            XCTAssertTrue(output.contains("FREEMIND_LIVE_READY"))
            await backend.stopAll()
            try await backend.start(pane)
            for _ in 0..<80 {
                try await Task.sleep(for: .milliseconds(250))
                output = (try? await backend.capture(pane.id)) ?? ""
                if output.contains("FREEMIND_LIVE_READY") { break }
            }
            let restored = try DurableFile.load(HookEvent.self, from: paths.terminal(pane.id).appendingPathComponent("session.json"))
            XCTAssertEqual(restored.sessionID, identity)
            output = try await backend.capture(pane.id)
            XCTAssertTrue(output.contains("FREEMIND_LIVE_READY"), "The resumed TUI must show the original conversation")
            XCTAssertFalse(output.contains("Do you trust the contents"))
            let record = "Live Codex verification: existing authentication, generated hook trust, automatic workspace trust, ANSI output, completed response, and exact conversation resume passed.\nConversation: \(identity)\n"
            try Data(record.utf8).write(to: repo.appendingPathComponent(".build-support/live-codex-verification.txt"), options: .atomic)
            await backend.stopAll(); try? FileManager.default.removeItem(at: root)
        } catch { await backend.stopAll(); try? Data(root.path.utf8).write(to: repo.appendingPathComponent(".build-support/failed-live-root.txt")); throw error }
    }
}
