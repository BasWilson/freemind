import XCTest
import AppKit
import FreemindCore
@testable import Freemind

final class ThemePromptTests: XCTestCase {
    @MainActor func testThemeDescriptionReachesCodexProcess() async throws {
        try await checkThemePrompt(retryFailedLaunch: false)
    }

    @MainActor func testThemeDescriptionSurvivesFailedLaunchAndRetry() async throws {
        try await checkThemePrompt(retryFailedLaunch: true)
    }

    @MainActor private func checkThemePrompt(retryFailedLaunch: Bool) async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind theme 'prompt " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = WorkspacePaths(root: root)
        let codex = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        printf '%s\\0' "$@" > "$FREEMIND_EVENT_DIR/received-arguments"
        exec /bin/sleep 60
        """
        try Data((retryFailedLaunch ? "#!/missing-freemind-test-interpreter\n" : script).utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = root.appendingPathComponent("empty-codex-home").path
        let backend = TerminalBackend(paths: paths, executable: repo.appendingPathComponent("Resources/bin/tmux").path,
                                      helper: repo.appendingPathComponent(".build/debug/freemind-helper").path, environment: environment)
        let workspace = try WorkspaceModel(root: root, environment: environment, terminalBackend: backend)
        var options = CodexOptions(); options.executable = codex.path; options.hooks = false
        let prompt = CustomThemeConfiguration.codexPrompt(theme: CustomTheme(name: "Tommy"),
                                                         request: "Ginger orange and white.\nKeep \"Tommy's\" colors warm 🐈; $(touch unwanted)")
        do {
            workspace.activate()
            let id = try XCTUnwrap(workspace.addPane(title: "Design a theme", options: options, prompt: prompt))
            let received = paths.terminal(id).appendingPathComponent("received-arguments")
            let recovery = paths.terminal(id).appendingPathComponent("recovery.json")
            if retryFailedLaunch {
                for _ in 0..<100 {
                    if await backend.snapshot().first(where: { $0.paneID == id })?.exitStatus == 1 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let failed = await backend.snapshot().first(where: { $0.paneID == id })
                XCTAssertEqual(failed?.exitStatus, 1)
                let output = try await backend.capture(id)
                XCTAssertTrue(output.contains("Could not launch"), "The launcher failure must be visible in the terminal")
                XCTAssertEqual(try TerminalPrompt.load(recoveryFile: recovery), prompt)
                try Data(script.utf8).write(to: codex)
                workspace.restartPane(id)
            }
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: received.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let arguments = try String(contentsOf: received, encoding: .utf8).split(separator: "\0").map(String.init)
            XCTAssertEqual(arguments.last, prompt)
            XCTAssertEqual(arguments.filter { $0 == prompt }.count, 1)
            XCTAssertNil(try TerminalPrompt.load(recoveryFile: recovery), "Consumed prompts must not be retained or replayed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unwanted").path))
            try FileManager.default.removeItem(at: received)
            workspace.restartPane(id)
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: received.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let restarted = try String(contentsOf: received, encoding: .utf8).split(separator: "\0").map(String.init)
            XCTAssertFalse(restarted.contains(prompt), "Restarting after delivery must not submit the theme request again")
            for session in workspace.sessions.values { session.disconnect() }
            await backend.stopAll()
            try FileManager.default.removeItem(at: root)
        } catch {
            for session in workspace.sessions.values { session.disconnect() }
            await backend.stopAll(); try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
