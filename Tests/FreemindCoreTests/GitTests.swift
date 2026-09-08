import XCTest
@testable import FreemindCore

final class GitTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try run(["init", "-b", "main"]); _ = try run(["config", "user.name", "Freemind Test"]); _ = try run(["config", "user.email", "test@freemind.invalid"])
        _ = try run(["config", "commit.gpgsign", "false"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func run(_ args: [String], at: URL? = nil) throws -> CommandResult {
        try CommandRunner.sync("/usr/bin/git", ["-C", (at ?? root).path] + args).checked()
    }
    func write(_ name: String, _ content: String) throws { try Data(content.utf8).write(to: root.appendingPathComponent(name)) }
    func seed() throws { try write("base.txt", "one\ntwo\n"); _ = try run(["add", "."]); _ = try run(["commit", "-m", "Initial"]) }

    func testUnbornStageUnstageCommitAndUnusualPaths() async throws {
        let name = "a space\nquote'🙂.txt"
        try write(name, "alpha\n")
        let service = GitService(folder: root)
        var snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.changes.first?.path, name)
        try await service.stage(snapshot.changes.first)
        snapshot = try await service.snapshot(); XCTAssertEqual(snapshot.changes.first?.section, .staged)
        try await service.unstage(nil)
        snapshot = try await service.snapshot(); XCTAssertEqual(snapshot.changes.first?.section, .untracked)
        try await service.stage(nil)
        _ = try await service.commit("A real commit\n\nWith a body.")
        snapshot = try await service.snapshot(); XCTAssertTrue(snapshot.changes.isEmpty)
        let message = try run(["log", "-1", "--format=%B"]).output
        XCTAssertTrue(message.contains("With a body."))
    }
    func testStagedAndUnstagedDiffsAndRenameDelete() async throws {
        try seed(); let service = GitService(folder: root)
        try write("base.txt", "one\nSTAGED\n"); try await service.stage(nil)
        try write("base.txt", "one\nWORKING\n")
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.changes.count, 2)
        let staged = try XCTUnwrap(snapshot.changes.first { $0.section == .staged })
        let unstaged = try XCTUnwrap(snapshot.changes.first { $0.section == .unstaged })
        let a = try await service.diff(staged), b = try await service.diff(unstaged)
        XCTAssertTrue(a.raw.contains("+STAGED")); XCTAssertFalse(a.raw.contains("+WORKING")); XCTAssertTrue(b.raw.contains("+WORKING"))
        _ = try run(["reset", "--hard", "HEAD"])
        _ = try run(["mv", "base.txt", "renamed.txt"])
        let renamed = try await service.snapshot()
        XCTAssertEqual(renamed.changes.first?.originalPath, "base.txt")
        try await service.unstage(renamed.changes.first)
        try await service.stage(nil); _ = try await service.commit("Rename")
        try FileManager.default.removeItem(at: root.appendingPathComponent("renamed.txt"))
        let deleted = try await service.snapshot(); XCTAssertEqual(deleted.changes.first?.status, "D")
        try await service.stage(deleted.changes.first); _ = try await service.commit("Delete")
    }
    func testPushFirstUpstreamAndRejectedPushPreservesCommit() async throws {
        try seed(); let service = GitService(folder: root)
        let remote = root.appendingPathComponent("remote.git"), other = root.appendingPathComponent("other")
        _ = try run(["init", "--bare", remote.path]); _ = try run(["remote", "add", "origin", remote.path])
        _ = try await service.push(remote: "origin", branch: "main")
        var snapshot = try await service.snapshot(); XCTAssertEqual(snapshot.upstream, "origin/main")
        _ = try run(["clone", "--branch", "main", remote.path, other.path])
        _ = try run(["config", "user.name", "Other Test"], at: other); _ = try run(["config", "user.email", "other@freemind.invalid"], at: other)
        _ = try run(["config", "commit.gpgsign", "false"], at: other)
        try Data("remote edit".utf8).write(to: other.appendingPathComponent("remote.txt"))
        _ = try run(["add", "remote.txt"], at: other); _ = try run(["commit", "-m", "Remote advancement"], at: other); _ = try run(["push"], at: other)
        try write("local.txt", "local edit")
        _ = try run(["add", "local.txt"]); _ = try await service.commit("Local advancement")
        let head = try run(["rev-parse", "HEAD"]).output
        do { _ = try await service.push(); XCTFail("Diverged push should fail") } catch {}
        XCTAssertEqual(try run(["rev-parse", "HEAD"]).output, head)
        try await service.fetch(); snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.ahead, 1); XCTAssertEqual(snapshot.behind, 1)
    }
    func testHookFailureAndConflictStatus() async throws {
        try seed(); let service = GitService(folder: root)
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho 'Intentional hook rejection' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("base.txt", "changed\n"); try await service.stage(nil)
        do { _ = try await service.commit("Rejected"); XCTFail("Hook should reject") } catch { XCTAssertTrue(error.localizedDescription.contains("Intentional hook rejection")) }
        try FileManager.default.removeItem(at: hook)
        _ = try run(["reset", "--hard", "HEAD"]); _ = try run(["checkout", "-b", "other"])
        try write("base.txt", "other\n"); _ = try run(["commit", "-am", "Other"]); _ = try run(["checkout", "main"])
        try write("base.txt", "main\n"); _ = try run(["commit", "-am", "Main"])
        _ = try CommandRunner.sync("/usr/bin/git", ["-C", root.path, "merge", "other"])
        let snapshot = try await service.snapshot(); XCTAssertTrue(snapshot.changes.contains { $0.conflicted })
    }
    func testBinaryLargePreviewWorktreeAndSubdirectory() async throws {
        try seed(); let service = GitService(folder: root)
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent("binary.bin"))
        try write("large.txt", String(repeating: "line\n", count: 7000))
        let snapshot = try await service.snapshot()
        let binary = try await service.diff(try XCTUnwrap(snapshot.changes.first { $0.path == "binary.bin" }))
        let large = try await service.diff(try XCTUnwrap(snapshot.changes.first { $0.path == "large.txt" }))
        XCTAssertTrue(binary.binary); XCTAssertTrue(large.truncated)
        let sub = root.appendingPathComponent("sub"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = GitService(folder: sub); let nestedRoot = try await nested.repositoryRoot(); XCTAssertEqual(nestedRoot.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        let worktree = root.appendingPathComponent("worktree")
        _ = try run(["worktree", "add", "-b", "feature", worktree.path])
        let worktreeService = GitService(folder: worktree); let worktreeSnapshot = try await worktreeService.snapshot(); XCTAssertEqual(worktreeSnapshot.branch, "feature")
    }
    func testBranchListAndLocalSwitchPreserveCompatibleChanges() async throws {
        try seed()
        _ = try run(["branch", "feature/🙂-ui"])
        _ = try run(["tag", "feature/🙂-ui"])
        try write("base.txt", "local edits\n")
        _ = try run(["add", "base.txt"])
        let subfolder = root.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let service = GitService(folder: subfolder)
        let branches = try await service.branches()
        XCTAssertEqual(branches.map(\.name), ["feature/🙂-ui", "main"])
        XCTAssertTrue(branches.allSatisfy { !$0.isRemote })
        let feature = try XCTUnwrap(branches.first { $0.name == "feature/🙂-ui" })
        _ = try await service.switchBranch(feature)
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, feature.name)
        XCTAssertEqual(snapshot.changes.first { $0.path == "base.txt" }?.section, .staged)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "local edits\n")
    }
    func testBlockedSwitchReportsConflictingChangesAndPreservesBranch() async throws {
        try seed()
        _ = try run(["checkout", "-b", "feature"])
        try write("base.txt", "feature content\n")
        try write("new.txt", "tracked on feature\n")
        _ = try run(["add", "."]); _ = try run(["commit", "-m", "Feature"])
        _ = try run(["checkout", "main"])
        let service = GitService(folder: root)
        let branches = try await service.branches()
        let feature = try XCTUnwrap(branches.first { $0.name == "feature" })
        try write("base.txt", "unsaved work\n")
        do { _ = try await service.switchBranch(feature); XCTFail("Must protect local changes") }
        catch { XCTAssertTrue(error.localizedDescription.contains("base.txt")); XCTAssertTrue(error.localizedDescription.contains("overwritten")) }
        var snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "unsaved work\n")
        _ = try run(["restore", "base.txt"])
        try write("new.txt", "untracked work\n")
        do { _ = try await service.switchBranch(feature); XCTFail("Must protect untracked files") }
        catch { XCTAssertTrue(error.localizedDescription.contains("new.txt")); XCTAssertTrue(error.localizedDescription.contains("overwritten")) }
        snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "untracked work\n")
    }
    func testRemoteBranchSwitchCreatesTrackingBranchAndOmitsHeadAlias() async throws {
        try seed()
        let remote = root.appendingPathComponent("remote.git")
        _ = try run(["init", "--bare", remote.path]); _ = try run(["remote", "add", "origin", remote.path])
        _ = try run(["push", "origin", "main", "main:feature/nested"])
        _ = try run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let service = GitService(folder: root)
        let branches = try await service.branches()
        XCTAssertFalse(branches.contains { $0.name == "origin/HEAD" })
        let branch = try XCTUnwrap(branches.first { $0.name == "origin/feature/nested" })
        XCTAssertTrue(branch.isRemote)
        _ = try await service.switchBranch(branch)
        var snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "feature/nested")
        XCTAssertEqual(snapshot.upstream, "origin/feature/nested")
        _ = try run(["checkout", "main"])
        do { _ = try await service.switchBranch(branch); XCTFail("An existing local branch must not be reset") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already exists")) }
        snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
    }
    func testMissingAndInvalidBranchErrorsDoNotChangeHead() async throws {
        try seed()
        let service = GitService(folder: root)
        _ = try run(["branch", "gone"])
        let branches = try await service.branches()
        let gone = try XCTUnwrap(branches.first { $0.name == "gone" })
        _ = try run(["branch", "-d", "gone"])
        do { _ = try await service.switchBranch(gone); XCTFail("Deleted branch should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer exists")) }
        for reference in ["refs/heads/--discard-changes", "refs/tags/main", "refs/heads/@{-1}"] {
            do { _ = try await service.switchBranch(GitBranch(reference: reference)); XCTFail("Invalid branch should fail") }
            catch { XCTAssertFalse(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
    }
    func testBranchCheckedOutInAnotherWorktreeReportsError() async throws {
        try seed()
        let worktree = root.appendingPathComponent("worktree")
        _ = try run(["worktree", "add", "-b", "feature", worktree.path])
        let service = GitService(folder: root)
        let branches = try await service.branches()
        let feature = try XCTUnwrap(branches.first { $0.name == "feature" })
        do { _ = try await service.switchBranch(feature); XCTFail("Must respect another worktree") }
        catch { XCTAssertTrue(error.localizedDescription.contains("worktree")) }
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
        let linked = GitService(folder: worktree)
        _ = try run(["branch", "available"])
        let linkedBranches = try await linked.branches()
        _ = try await linked.switchBranch(try XCTUnwrap(linkedBranches.first { $0.name == "available" }))
        let linkedSnapshot = try await linked.snapshot()
        XCTAssertEqual(linkedSnapshot.branch, "available")
    }
    func testUnbornAndDetachedBranchSelection() async throws {
        let service = GitService(folder: root)
        let empty = try await service.branches()
        XCTAssertTrue(empty.isEmpty)
        var snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
        try seed()
        _ = try run(["checkout", "--detach"])
        snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "Detached HEAD")
        let branches = try await service.branches()
        _ = try await service.switchBranch(try XCTUnwrap(branches.first { $0.name == "main" }))
        snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.branch, "main")
    }
    func testCurrentBranchReadsExternalSwitchInLinkedWorktree() async throws {
        try seed()
        let worktree = root.appendingPathComponent("worktree")
        _ = try run(["worktree", "add", "-b", "feature", worktree.path])
        let service = GitService(folder: worktree)
        var branch = try await service.currentBranch()
        XCTAssertEqual(branch, "feature")
        _ = try run(["checkout", "-b", "external"], at: worktree)
        branch = try await service.currentBranch()
        XCTAssertEqual(branch, "external")
    }
    func testInvalidRepositoryAndUnreadableStatusAreDistinctErrors() async throws {
        try seed()
        let service = GitService(folder: root)
        try Data("broken index".utf8).write(to: root.appendingPathComponent(".git/index"))
        do { _ = try await service.snapshot(); XCTFail("Corrupt index must be reported") }
        catch { XCTAssertFalse(error is GitRepositoryError); XCTAssertTrue(error.localizedDescription.contains("index")) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        do { _ = try await service.snapshot(); XCTFail("Missing repository must be reported") }
        catch { XCTAssertTrue(error is GitRepositoryError) }
    }
}
