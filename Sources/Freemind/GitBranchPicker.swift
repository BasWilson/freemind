import SwiftUI
import FreemindCore

struct GitBranchButton: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var model: GitModel
    @State private var showingBranches = false

    var body: some View {
        Button { showingBranches = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(theme.accent)
                Text(model.snapshot?.branch ?? (model.notRepository ? "No Git repository" : "Reading Git…"))
                    .lineLimit(1).truncationMode(.middle)
                if model.operation != nil { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
            }.font(.system(size: 12, weight: .medium)).frame(maxWidth: 220)
        }
        .buttonStyle(.borderless)
        .disabled(model.operation != nil)
        .help("Switch branches · \(model.snapshot?.branch ?? "Git")")
        .accessibilityLabel("Switch Git branch, current branch: \(model.snapshot?.branch ?? "unavailable")")
        .popover(isPresented: $showingBranches, arrowEdge: .bottom) {
            GitBranchPicker(model: model)
        }
    }
}

private struct GitBranchPicker: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: GitModel
    @State private var search = ""

    private var filteredBranches: [GitBranch] {
        model.branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Switch branch").font(.headline)
                Spacer()
                Button { Task { await model.refresh(); await model.refreshBranches() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh branches")
                    .disabled(model.branchesLoading || model.operation != nil)
            }
            if let snapshot = model.snapshot {
                Text("Current: \(snapshot.branch)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            TextField("Search branches…", text: $search).textFieldStyle(.roundedBorder)
                .disabled(model.operation != nil)
            if let error = model.branchesError { GitErrorMessage(text: error) { model.branchesError = nil } }
            if let error = model.error { GitErrorMessage(text: error) { model.error = nil } }
            if let operation = model.operation {
                HStack { ProgressView().controlSize(.small); Text(operation).font(.caption) }
            }
            if model.branchesLoading {
                ProgressView("Loading branches…").frame(maxWidth: .infinity, minHeight: 90)
            } else if filteredBranches.isEmpty {
                Text(model.branchesError != nil ? "Use Refresh to try again." : !search.isEmpty ? "No branches match your search." : model.notRepository ? "Initialize Git in a terminal, then refresh." : "No branches to switch to yet. Make a commit to create your first branch.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        branchSection("Local branches", remote: false)
                        branchSection("Remote branches", remote: true)
                    }
                }.frame(maxHeight: 300)
            }
            Text("Git keeps compatible local changes and blocks switches that would overwrite them. Remote branches create a local tracking branch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 380)
        .task { await model.refresh(); await model.refreshBranches() }
    }

    @ViewBuilder private func branchSection(_ title: String, remote: Bool) -> some View {
        let branches = filteredBranches.filter { $0.isRemote == remote }
        if !branches.isEmpty {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(branches) { branch in
                let current = !branch.isRemote && branch.name == model.snapshot?.branch
                Button {
                    Task { if await model.switchBranch(branch) { dismiss() } }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: current ? "checkmark" : branch.isRemote ? "network" : "arrow.triangle.branch")
                            .frame(width: 16).foregroundStyle(current ? theme.accent : .secondary)
                        Text(branch.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if current { Text("Current").font(.caption).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 12)).padding(8).contentShape(Rectangle())
                    .background(current ? theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).disabled(current || model.operation != nil)
                .help(branch.name)
                .accessibilityLabel(current ? "\(branch.name), current branch" : "Switch to \(branch.name)")
            }
        }
    }
}

struct GitErrorBanner: View {
    @ObservedObject var model: GitModel
    var body: some View {
        if let error = model.error { GitErrorMessage(text: error) { model.error = nil }.padding(10).background(Color.orange.opacity(0.07)) }
        else if let error = model.branchesError { GitErrorMessage(text: error) { model.branchesError = nil }.padding(10).background(Color.orange.opacity(0.07)) }
    }
}

private struct GitErrorMessage: View {
    let text: String
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            ScrollView {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.frame(maxHeight: 120)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss Git error")
        }.foregroundStyle(.orange)
    }
}
