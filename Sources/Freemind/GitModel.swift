import Foundation
import FreemindCore

@MainActor
final class GitModel: ObservableObject {
    let service: GitService
    @Published var snapshot: GitSnapshot?
    @Published var diff: DiffPreview?
    @Published var selected: GitChange?
    @Published var loading = false
    @Published var operation: String?
    @Published var error: String?
    @Published var feedback: String?
    @Published var notRepository = false
    @Published var branches: [GitBranch] = []
    @Published var branchesLoading = false
    @Published var branchesError: String?
    private var refreshTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var refreshing = false
    private var refreshPending = false
    private var revision = 0
    init(folder: URL, environment: [String: String]) { service = GitService(folder: folder, environment: environment) }
    func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { await refresh() } }
    }
    func refreshCurrentBranch() async {
        guard snapshot != nil, operation == nil, !refreshing else { return }
        let revision = self.revision
        do {
            let branch = try await service.currentBranch()
            guard revision == self.revision, operation == nil else { return }
            if snapshot?.branch != branch { await refresh() }
        } catch is CancellationError {} catch {
            guard revision == self.revision, operation == nil else { return }
            // A full refresh distinguishes a removed repository from a Git failure.
            await refresh()
        }
    }
    func refresh() async {
        guard operation == nil else { return }
        guard !refreshing else { refreshPending = true; return }
        refreshing = true; loading = snapshot == nil
        let revision = self.revision
        defer {
            refreshing = false; loading = false
            if refreshPending { refreshPending = false; Task { await refresh() } }
        }
        do {
            let value = try await service.snapshot()
            guard revision == self.revision, operation == nil else { return }
            snapshot = value; notRepository = false
            if let selected, let new = value.changes.first(where: { $0.id == selected.id }) { self.selected = new; loadDiff(new) }
            else if let first = value.changes.first { select(first) } else { diffTask?.cancel(); selected = nil; diff = nil }
            await refreshBranches()
        } catch is CancellationError {} catch {
            guard revision == self.revision, operation == nil else { return }
            if error is GitRepositoryError { notRepository = true; snapshot = nil; branches = []; branchesError = nil; diffTask?.cancel(); selected = nil; diff = nil }
            else { notRepository = false; if self.error == nil { self.error = "Could not refresh Git.\n\n" + error.localizedDescription } }
        }
    }
    func select(_ change: GitChange) { selected = change; loadDiff(change) }
    private func loadDiff(_ change: GitChange) {
        diffTask?.cancel(); diff = nil; let id = change.id
        diffTask = Task {
            do { let value = try await service.diff(change); if selected?.id == id && !Task.isCancelled { diff = value } }
            catch is CancellationError {} catch { if !Task.isCancelled, selected?.id == id, self.error == nil { self.error = error.localizedDescription } }
        }
    }
    func perform(_ label: String, body: @escaping () async throws -> String) async -> Bool {
        guard operation == nil else { return false }
        operation = label; error = nil; feedback = nil; revision += 1; diffTask?.cancel()
        let success: Bool
        do { feedback = try await body(); success = true }
        catch { self.error = error.localizedDescription; success = false }
        operation = nil; await refresh(); return success
    }
    func stage(_ change: GitChange?) { Task { _ = await perform("Staging…") { try await self.service.stage(change); return "Changes staged" } } }
    func unstage(_ change: GitChange?) { Task { _ = await perform("Unstaging…") { try await self.service.unstage(change); return "Changes unstaged" } } }
    func refreshBranches() async {
        guard !branchesLoading, operation == nil else { return }
        branchesLoading = true; branchesError = nil
        let revision = self.revision
        defer { branchesLoading = false }
        do {
            let value = try await service.branches()
            guard revision == self.revision, operation == nil, !notRepository else { return }
            if branches != value { branches = value }
        }
        catch is CancellationError {} catch {
            guard revision == self.revision, operation == nil, !notRepository else { return }
            branchesError = "Could not load branches.\n\n" + error.localizedDescription
        }
    }
    func switchBranch(_ branch: GitBranch) async -> Bool {
        let success = await perform("Switching to \(branch.name)…") {
            do { return try await self.service.switchBranch(branch) }
            catch { throw FreemindError.message("Could not switch to ‘\(branch.name)’.\n\n" + error.localizedDescription) }
        }
        return success
    }
}
