import Foundation
import FreemindCore

enum TestExecutables {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func tmux(environment: [String: String]) throws -> String {
        if let override = environment["FREEMIND_TMUX"] { return try executable([override], name: "tmux") }
        #if os(macOS)
        let bundled = [repository.appendingPathComponent("Resources/bin/tmux").path]
        #else
        let bundled: [String] = []
        #endif
        let candidates = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { String($0) + "/tmux" }
        return try executable(bundled + candidates, name: "tmux (install tmux or set FREEMIND_TMUX)")
    }

    static func helper(environment: [String: String]) throws -> String {
        if let override = environment["FREEMIND_HELPER"] { return try executable([override], name: "freemind-helper") }
        // Linux XCTest is a sibling executable; macOS XCTest lives inside a bundle.
        var folder = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        var candidates: [String] = []
        #if os(macOS)
        candidates.append(Bundle(for: TerminalTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("freemind-helper").path)
        #endif
        for _ in 0..<4 {
            candidates.append(folder.appendingPathComponent("freemind-helper").path)
            folder.deleteLastPathComponent()
        }
        return try executable(candidates, name: "freemind-helper (build it or set FREEMIND_HELPER)")
    }

    private static func executable(_ candidates: [String], name: String) throws -> String {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FreemindError.message("Missing test dependency: \(name)")
        }
        return path
    }
}
