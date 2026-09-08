import Foundation
import FreemindCore
import LinuxUI

extension Controller {
    func handleGit(_ action: String, value: String) async throws -> Bool {
        guard let service = gitService else { return true }
        switch action {
        case "commit-draft": restoration.commitDraft = value
        case "git-branches":
            let branches = try await service.branches(); gitBranches = branches
            await onUI {
                fm_palette_begin("Switch Git branch")
                for branch in branches { fm_palette_item(branch.name, branch.isRemote ? "Remote tracking branch" : "Local branch", "git-switch", branch.reference) }
                fm_palette_end()
            }
        case "git-refresh": try await refreshGit()
        case "git-select":
            selectedChange = gitSnapshot?.changes.first { $0.id == value }; try await showDiff()
        case "git-diff-mode": gitSplitDiff.toggle(); try await showDiff()
        case "git-open-file":
            if let selectedChange, let root = gitSnapshot?.root { try await openFile(root.appendingPathComponent(selectedChange.path).path) }
        case "git-push":
            guard let snapshot = gitSnapshot else { try await refreshGit(); return true }
            if snapshot.upstream == nil {
                let remotes = snapshot.remotes.joined(separator: ", ")
                await onUI { fm_prompt("Publish branch", "Enter a remote and branch on separate lines. Available remotes: " + remotes, (snapshot.remotes.first ?? "origin") + "\n" + snapshot.branch, "git-publish") }
            } else { try await startGitOperation(action, value: value, service: service) }
        case "git-stage", "git-unstage", "git-fetch", "git-commit", "git-commit-push", "git-switch", "git-publish":
            try await startGitOperation(action, value: value, service: service)
        case "git-finished":
            gitOperations.remove(value)
            if value == paths?.root.path { try await refreshGit(); let text = gitFeedback; await onUI { fm_git_message(text) } }
        default: return false
        }
        return true
    }
    func startGitOperation(_ action: String, value: String, service: GitService) async throws {
        guard !gitWorking else { throw FreemindError.message("A Git operation is already running.") }
        let change = gitSnapshot?.changes.first { $0.id == value }
        if !value.isEmpty && ["git-stage", "git-unstage"].contains(action) && change == nil { throw FreemindError.message("The selected Git change is no longer available. Refresh Git first.") }
        let branch = gitBranches.first { $0.reference == value }
        let message = restoration.commitDraft, root = paths?.root.path ?? ""
        gitOperations.insert(root); await onUI { fm_git_message("Working…") }
        Task {
            var result = "", success = false
            do {
                switch action {
                case "git-stage": try await service.stage(change); result = "Changes staged."
                case "git-unstage": try await service.unstage(change); result = "Changes unstaged."
                case "git-fetch": try await service.fetch(); result = "Fetch complete."
                case "git-push": result = try await service.push()
                case "git-publish":
                    let fields = value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard fields.count == 2 else { throw FreemindError.message("Enter the remote and branch on separate lines.") }
                    result = try await service.push(remote: fields[0], branch: fields[1])
                case "git-switch":
                    guard let branch else { throw FreemindError.message("Choose an existing branch.") }
                    result = try await service.switchBranch(branch)
                case "git-commit", "git-commit-push":
                    result = try await service.commit(message)
                    if paths?.root.path == root && restoration.commitDraft == message { restoration.commitDraft = "" }
                    if action == "git-commit-push" {
                        do { result += "\n" + (try await service.push()) }
                        catch { throw FreemindError.message("Commit succeeded. Push failed: " + error.localizedDescription) }
                    }
                default: break
                }
                success = true
            } catch { result = error.localizedDescription }
            gitFeedback = result
            gitOperations.remove(root)
            if paths?.root.path == root {
                do { try await refreshGit() } catch { gitFeedback += "\n" + error.localizedDescription }
                let feedback = gitFeedback
                await onUI { fm_git_message(feedback); if !success { fm_error(feedback) } }
            }
        }
    }
    func refreshGit() async throws {
        guard let service = gitService, !gitWorking else { return }
        lastGitCheck = Date()
        let root = paths?.root
        do {
            let snapshot = try await service.snapshot()
            let loadedBranches = try await service.branches()
            guard paths?.root == root, gitService === service else { return }
            gitSnapshot = snapshot; gitBranches = loadedBranches
            if let old = selectedChange { selectedChange = snapshot.changes.first { $0.id == old.id } }
            if selectedChange == nil { selectedChange = snapshot.changes.first }
            let selected = selectedChange?.id, draft = restoration.commitDraft, branches = gitBranches
            let summary = "\(snapshot.branch)  ↑\(snapshot.ahead) ↓\(snapshot.behind)\n+\(snapshot.added) −\(snapshot.deleted) · \(snapshot.changes.count) changes"
            await onUI {
                fm_branch(snapshot.branch)
                fm_git_clear(summary, draft)
                for section in GitSection.allCases {
                    for change in snapshot.changes where change.section == section { fm_git_row(change.id, change.path, change.conflicted ? "Conflict" : change.status, section.rawValue, selected == change.id ? 1 : 0) }
                }
                fm_git_branches(([""] + branches.map(\.reference)).joined(separator: "\n"), ([snapshot.branch] + branches.map(\.name)).joined(separator: "\n"), "refs/heads/" + snapshot.branch)
            }
            try await showDiff()
        } catch is GitRepositoryError {
            guard paths?.root == root, gitService === service else { return }
            gitSnapshot = nil; selectedChange = nil
            await onUI { fm_git_clear("This folder is not a Git repository.", ""); fm_git_diff("", 0); fm_git_message("Open a Git repository to view changes.") }
        }
    }
    func showDiff() async throws {
        guard let service = gitService, let selectedChange else { await onUI { fm_git_diff("Working tree clean.", 0) }; return }
        let root = paths?.root
        let diff = try await service.diff(selectedChange), split = gitSplitDiff
        guard paths?.root == root, self.selectedChange?.id == selectedChange.id, gitService === service else { return }
        let text = diff.lines.map(\.text).joined(separator: "\n") + (diff.truncated ? "\n… Diff preview limited to 6,000 lines." : "")
        await onUI { fm_git_diff(text, split ? 1 : 0) }
    }
}
