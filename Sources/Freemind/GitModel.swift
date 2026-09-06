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
    private var refreshTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var refreshing = false
    init(folder: URL, environment: [String: String]) { service = GitService(folder: folder, environment: environment) }
    func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { await refresh() } }
    }
    func refresh() async {
        guard !refreshing, operation == nil else { return }; refreshing = true; loading = snapshot == nil
        defer { refreshing = false; loading = false }
        do {
            let value = try await service.snapshot()
            snapshot = value; notRepository = false
            if let selected, let new = value.changes.first(where: { $0.id == selected.id }) { self.selected = new; loadDiff(new) }
            else if let first = value.changes.first { select(first) } else { selected = nil; diff = nil }
        } catch is CancellationError {} catch {
            if snapshot == nil { notRepository = true } else { self.error = error.localizedDescription }
        }
    }
    func select(_ change: GitChange) { selected = change; loadDiff(change) }
    private func loadDiff(_ change: GitChange) {
        diffTask?.cancel(); let id = change.id
        diffTask = Task {
            do { let value = try await service.diff(change); if selected?.id == id && !Task.isCancelled { diff = value } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func perform(_ label: String, body: @escaping () async throws -> String) async -> Bool {
        guard operation == nil else { return false }
        operation = label; error = nil; feedback = nil
        let success: Bool
        do { feedback = try await body(); success = true }
        catch { self.error = error.localizedDescription; success = false }
        operation = nil; await refresh(); return success
    }
    func stage(_ change: GitChange?) { Task { _ = await perform("Staging…") { try await self.service.stage(change); return "Changes staged" } } }
    func unstage(_ change: GitChange?) { Task { _ = await perform("Unstaging…") { try await self.service.unstage(change); return "Changes unstaged" } } }
}
