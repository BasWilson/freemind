import XCTest
@testable import FreemindCore

final class CommandRunnerTests: XCTestCase {
    func testLargeInputAndBothOutputPipes() async throws {
        let input = Data(String(repeating: "0123456789🙂\n", count: 20000).utf8)
        let result = try await CommandRunner.run("/bin/sh", ["-c", "cat; printf diagnostic >&2; exit 7"], input: input)
        XCTAssertEqual(result.stdout, input)
        XCTAssertEqual(result.error, "diagnostic")
        XCTAssertEqual(result.code, 7)
    }
    func testEarlyExitWhileWritingInput() async throws {
        let result = try await CommandRunner.run("/bin/sh", ["-c", "exit 0"], input: Data(repeating: 1, count: 1024 * 1024))
        XCTAssertEqual(result.code, 0)
    }
    func testTimeoutStopsAChildIgnoringTermination() async throws {
        let start = Date()
        let result = try await CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertNotEqual(result.code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testCancellationReapsChild() async throws {
        let task = Task { try await CommandRunner.run("/bin/sh", ["-c", "while :; do :; done"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must be reported") }
        catch is CancellationError { }
    }
    func testMissingExecutableThrows() async {
        do { _ = try await CommandRunner.run("/nonexistent/freemind-executable"); XCTFail("Missing executable must fail") }
        catch { }
    }
}
