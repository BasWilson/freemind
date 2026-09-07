import XCTest
import Combine
import FreemindCore
@testable import Freemind

final class GitModelTests: XCTestCase {
    @MainActor func testWorkspaceRefreshPreloadsBranchesAndPreservesThemWhileRefreshing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-branch-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws {
            _ = try CommandRunner.sync("/usr/bin/git", ["-C", root.path] + args).checked()
        }
        try git(["init", "-b", "main"])
        try git(["-c", "user.name=Freemind Test", "-c", "user.email=test@freemind.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"])
        try git(["branch", "feature"])
        let model = GitModel(folder: root, environment: ProcessInfo.processInfo.environment)
        await model.refresh()
        XCTAssertEqual(model.snapshot?.branch, "main")
        XCTAssertEqual(model.branches.map(\.name), ["feature", "main"], "Branches should be ready before the picker is opened")

        var publishedLists: [[GitBranch]] = []
        let observer = model.$branches.sink { publishedLists.append($0) }
        let cached = model.branches
        try git(["branch", "new-branch"])
        await model.refresh()
        XCTAssertEqual(publishedLists.first, cached)
        XCTAssertFalse(publishedLists.contains(where: \.isEmpty), "A background refresh must keep the cached list visible")
        XCTAssertEqual(model.branches.map(\.name), ["feature", "main", "new-branch"])
        let feature = try XCTUnwrap(model.branches.first { $0.name == "feature" })
        let switched = await model.switchBranch(feature)
        XCTAssertTrue(switched)
        XCTAssertEqual(model.snapshot?.branch, "feature")
        XCTAssertEqual(model.branches.map(\.name), ["feature", "main", "new-branch"])
        XCTAssertNil(model.branchesError)

        // A failed branch refresh retains the last useful result and reports its error.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        await model.refreshBranches()
        XCTAssertFalse(model.branches.isEmpty)
        XCTAssertNotNil(model.branchesError)
        await model.refresh()
        XCTAssertTrue(model.notRepository)
        XCTAssertTrue(model.branches.isEmpty)
        XCTAssertNil(model.branchesError)
        withExtendedLifetime(observer) {}
    }
}
