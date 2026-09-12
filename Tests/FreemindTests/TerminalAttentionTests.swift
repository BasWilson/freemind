import AppKit
import XCTest
import FreemindCore
@testable import Freemind

final class TerminalAttentionTests: XCTestCase {
    @MainActor func testOnlyLiveNotificationsRequestAttention() throws {
        _ = NSApplication.shared
        let paths = WorkspacePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let backend = TerminalBackend(paths: paths, executable: "/usr/bin/false", helper: "/usr/bin/false", environment: [:])
        let session = TerminalSession(pane: PaneDefinition(title: "Codex"), backend: backend, paths: paths)
        var sounds = 0
        session.playAttentionSound = { sounds += 1 }
        func hook(_ name: String, agent: String? = nil) throws -> HookEvent {
            var payload = ["hook_event_name": name]
            payload["agent_id"] = agent
            return try HookEvent.parse(JSONSerialization.data(withJSONObject: payload))
        }

        for name in ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"] {
            session.receive(try hook(name))
            XCTAssertFalse(session.needsAttention)
            XCTAssertEqual(sounds, 0)
        }
        XCTAssertEqual(session.status, "Done")
        // Progress reports and raw BEL must not become attention notifications.
        session.view.feed(text: "\u{1B}]9;4;1;50\u{7}\u{7}")
        XCTAssertEqual(sounds, 0)
        let staleWorking = try hook("PostToolUse")
        session.view.feed(text: "\u{1B}]9;Task complete\u{7}")
        XCTAssertTrue(session.needsAttention)
        XCTAssertEqual(sounds, 1)
        session.receive(staleWorking)
        session.receive(try hook("PreToolUse", agent: "child"))
        XCTAssertTrue(session.needsAttention)
        session.view.feed(text: "\u{1B}]9;Task complete\u{7}")
        XCTAssertEqual(sounds, 1)

        session.receive(try hook("UserPromptSubmit"))
        XCTAssertFalse(session.needsAttention)
        session.receive(try hook("PermissionRequest"))
        XCTAssertEqual(session.status, "Working")
        XCTAssertEqual(sounds, 1)
        session.view.feed(text: "\u{1B}]9;Approval requested: test\u{7}")
        XCTAssertEqual(session.status, "Needs attention")
        XCTAssertTrue(session.needsAttention)
        XCTAssertEqual(sounds, 2)
        session.receive(try hook("PostToolUse"))
        XCTAssertFalse(session.needsAttention)
        session.view.feed(text: "\u{1B}]9;Plan mode prompt: Choose an option\u{7}")
        XCTAssertTrue(session.needsAttention)
        XCTAssertEqual(sounds, 3)
    }
}
