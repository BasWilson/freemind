import Foundation
import CryptoKit
import Darwin

public enum HookConfiguration {
    public static let events = ["SessionStart": "session_start", "SessionEnd": "session_end", "UserPromptSubmit": "user_prompt_submit",
                                "PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use", "PermissionRequest": "permission_request",
                                "Stop": "stop", "Interrupt": "interrupt", "PreCompact": "pre_compact", "PostCompact": "post_compact"]
    public static func make(helper: String, home: URL) throws -> (json: Data, trustTOML: String) {
        // Codex uses realpath identity. Foundation deliberately shortens /private/var
        // to /var on macOS, which otherwise makes every hook appear untrusted.
        let canonicalHome: URL
        if let path = realpath(home.path, nil) {
            canonicalHome = URL(fileURLWithPath: String(cString: path)); free(path)
        } else { canonicalHome = home }
        let command = ArgumentTokenizer.quote(helper) + " hook \"$FREEMIND_EVENT_DIR\""
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": 2, "async": false]
        var hooks: [String: Any] = [:], trust = ""
        for (event, key) in events.sorted(by: { $0.key < $1.key }) {
            hooks[event] = [["hooks": [handler]]]
            // Trust only the generated observation hook, using Codex's normalized identity.
            // No global hook-trust or approval bypass is used.
            let normalized: [String: Any] = ["event_name": key, "hooks": [handler]]
            let bytes = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .withoutEscapingSlashes])
            let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let identity = canonicalHome.appendingPathComponent("hooks.json").path + ":\(key):0:0"
            trust += "\n[hooks.state.\(CodexOptions.toml(identity))]\nenabled = true\ntrusted_hash = \(CodexOptions.toml(hash))\n"
        }
        return (try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), trust)
    }
}
