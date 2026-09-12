import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import FreemindCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
do {
    guard args.count >= 2 else { fail("Usage: freemind-helper launch <request.json> | hook <event-directory>") }
    if args[0] == "pane-exited" {
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { exit(0) }
        // A wakeup only: the UI reads the backend's actual exit status before
        // removing anything, so an old event can never close a restarted pane.
        try DurableFile.save(Date(), to: dir.appendingPathComponent("exit-event.json"))
        exit(0)
    } else if args[0] == "hook" {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let event = try HookEvent.parse(input)
        // Subagent hooks share the parent session ID; they must not overwrite its activity.
        guard event.agentID == nil else { exit(0) }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { exit(0) }
        try DurableFile.save(event, to: dir.appendingPathComponent("event.json"))
        if event.event == "SessionStart" { try DurableFile.save(event, to: dir.appendingPathComponent("session.json")) }
        // Observation only: empty successful output never approves, blocks, or changes a prompt.
        exit(0)
    } else if args[0] == "launch" {
        let url = URL(fileURLWithPath: args[1])
        let request = try DurableFile.load(LaunchRequest.self, from: url)
        let recoveryURL = URL(fileURLWithPath: request.recoveryFile)
        var recovery = (try? DurableFile.load(PaneRecovery.self, from: recoveryURL)) ?? PaneRecovery()
        var arguments = request.arguments
        if let prompt = request.initialPrompt, !prompt.isEmpty { arguments.append(prompt) }
        guard chdir(request.directory) == 0 else { fail("Cannot open workspace directory: \(request.directory)") }
        recovery.hasLaunched = true
        try DurableFile.save(recovery, to: recoveryURL)
        try TerminalPrompt.remove(recoveryFile: recoveryURL)
        // Do not retain an environment snapshot or initial prompt after the launch has claimed it.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
        let argv = ([request.executable] + arguments).map { strdup($0) } + [nil]
        let env = request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        request.executable.withCString { ptr in
            argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in _ = execve(ptr, a.baseAddress!, e.baseAddress!) } }
        }
        let launchError = String(cString: strerror(errno))
        if let prompt = request.initialPrompt { try TerminalPrompt.save(prompt, recoveryFile: recoveryURL) }
        fail("Could not launch \(request.executable): \(launchError)")
    } else { fail("Unknown helper command") }
} catch { fail(error.localizedDescription) }
