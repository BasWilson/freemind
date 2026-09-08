#if os(Linux)
import Foundation
import Glibc
import LinuxProcess

// Foundation's Linux Process waits for an inherited socket to close before
// waitpid. A daemonized tmux server can retain it indefinitely. Own and reap
// exactly the spawned PID instead, with close-on-exec descriptors.
private final class LinuxProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    func launch(_ body: () throws -> pid_t) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        pid = try body()
    }
    func signal(_ value: Int32, cancel: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if cancel { cancelled = true }
        if pid > 0 { _ = Glibc.kill(pid, value) }
    }
    func reap() throws -> Int32? {
        lock.lock(); defer { lock.unlock() }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 || (result < 0 && errno == EINTR) { return nil }
        let error = errno
        pid = 0 // Retire before timeout/cancellation can signal a reused PID.
        if cancelled { throw CancellationError() }
        if result < 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .ECHILD) }
        return fm_exit_status(status)
    }
}

enum LinuxCommandRunner {
    static func run(_ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String]?, input: Data?, timeout: Double) async throws -> CommandResult {
        let control = LinuxProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try sync(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout, control: control)
            }.value
        } onCancel: {
            control.signal(SIGTERM, cancel: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { control.signal(SIGKILL) }
        }
    }

    static func sync(_ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String]?, input: Data?, timeout: Double) throws -> CommandResult {
        try sync(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout, control: LinuxProcessControl())
    }

    private static func sync(_ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String]?, input: Data?, timeout: Double, control: LinuxProcessControl) throws -> CommandResult {
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        let handles = [out.fileHandleForReading, out.fileHandleForWriting, err.fileHandleForReading,
                       err.fileHandleForWriting, stdin.fileHandleForReading, stdin.fileHandleForWriting]
        defer { for handle in handles { try? handle.close() } }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + env { free(value) } }
        try control.launch {
            var pid: pid_t = 0
            let result = argv.withUnsafeBufferPointer { a in
                env.withUnsafeBufferPointer { e in
                    fm_spawn(&pid, executable, a.baseAddress!, e.baseAddress!, cwd?.path,
                             stdin.fileHandleForReading.fileDescriptor, out.fileHandleForWriting.fileDescriptor, err.fileHandleForWriting.fileDescriptor)
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            return pid
        }
        try? stdin.fileHandleForReading.close()
        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        let input = input ?? Data()
        var inputOffset = 0, inputOpen = true
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        // Nonblocking reads avoid waiting for EOF on descriptors inherited by
        // grandchildren, while draining both output streams without deadlocks.
        let descriptors = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var output = [Data(), Data()], buffer = [UInt8](repeating: 0, count: 65536)
        let started = DispatchTime.now().uptimeNanoseconds
        var terminatedAt: UInt64?
        var status: Int32?
        repeat {
            if inputOpen {
                if inputOffset < input.count {
                    let written = input.withUnsafeBytes { bytes in
                        fm_write(inputFD, bytes.baseAddress!.advanced(by: inputOffset), min(65536, input.count - inputOffset))
                    }
                    if written > 0 { inputOffset += written }
                    else if written < 0 && errno != EAGAIN && errno != EINTR { inputOffset = input.count }
                }
                if inputOffset == input.count {
                    try? stdin.fileHandleForWriting.close(); inputOpen = false
                }
            }
            for (index, fd) in descriptors.enumerated() {
                // Bound each drain so a noisy child cannot starve cancellation.
                for _ in 0..<16 {
                    let count = Glibc.read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    output[index].append(contentsOf: buffer.prefix(min(count, max(0, 32 * 1024 * 1024 - output[index].count))))
                }
            }
            if status != nil { break } // One final drain after waitpid.
            status = try control.reap()
            let now = DispatchTime.now().uptimeNanoseconds
            if status == nil, Double(now - started) / 1_000_000_000 >= max(0, timeout), terminatedAt == nil {
                control.signal(SIGTERM); terminatedAt = now
            }
            if let terminatedAt, now - terminatedAt >= 2_000_000_000 { control.signal(SIGKILL) }
            if status == nil { usleep(5000) }
        } while true
        return CommandResult(code: status!, stdout: output[0], stderr: output[1])
    }
}
#endif
