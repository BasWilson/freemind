import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CommandResult: Sendable {
    public let code: Int32
    public let stdout: Data
    public let stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var error: String { String(decoding: stderr, as: UTF8.self) }
    public func checked() throws -> CommandResult {
        guard code == 0 else { throw FreemindError.message(error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? output : error) }
        return self
    }
}
private final class ProcessControl: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        process = value
        try value.run()
    }
    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
}
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 32 * 1024 * 1024 - data.count)))
    }
}
public enum CommandRunner {
    public static func run(_ executable: String, _ arguments: [String] = [], cwd: URL? = nil,
                           environment: [String: String]? = nil, input: Data? = nil, timeout: Double = 30) async throws -> CommandResult {
        #if os(Linux)
        return try await LinuxCommandRunner.run(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout)
        #else
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try sync(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout, control: control)
            }.value
        } onCancel: { control.cancel() }
        #endif
    }
    public static func sync(_ executable: String, _ arguments: [String] = [], cwd: URL? = nil,
                            environment: [String: String]? = nil, input: Data? = nil, timeout: Double = 30) throws -> CommandResult {
        #if os(Linux)
        return try LinuxCommandRunner.sync(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout)
        #else
        try sync(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout, control: ProcessControl())
        #endif
    }
    private static func sync(_ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String]?, input: Data?, timeout: Double, control: ProcessControl) throws -> CommandResult {
        let process = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        #if os(macOS)
        // A child can exit before consuming its input. Return EPIPE to the writer
        // instead of delivering SIGPIPE to the whole app (or XCTest process).
        if input != nil, fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            throw FreemindError.message("Could not configure command input: \(String(cString: strerror(errno)))")
        }
        #endif
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = cwd; process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardOutput = out; process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try control.install(process)
        let group = DispatchGroup(), stdout = DataBox(), stderr = DataBox()
        for (pipe, box) in [(out, stdout), (err, stderr)] {
            group.enter()
            DispatchQueue.global().async {
                // Drain completely, but cap memory used by a runaway child.
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    box.append(chunk)
                }
                group.leave()
            }
        }
        if let input { DispatchQueue.global().async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() } }
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit(); deadline.cancel()
        // A daemonized child may inherit descriptors. Closing on timeout prevents a stuck reader.
        if group.wait(timeout: .now() + 2) == .timedOut {
            try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 1)
        }
        if control.isCancelled { throw CancellationError() }
        return CommandResult(code: process.terminationStatus, stdout: stdout.value, stderr: stderr.value)
    }
}

public actor OperationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
