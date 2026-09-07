import SwiftUI
import FreemindCore

struct GitView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.workspaceWindowID) private var windowID
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var model: GitModel
    @State private var sideBySide = false
    @State private var pushSetup = false
    @State private var remote = ""
    @State private var branch = ""
    var body: some View {
        VStack(spacing: 0) {
            if model.notRepository {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.secondary)
                    Text("This folder is not a Git repository.").font(.headline)
                    Text("Initialize Git in a terminal, then refresh.").foregroundStyle(.secondary)
                    Button("Refresh") { Task { await model.refresh() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                repositoryBar
                if let feedback = model.feedback { message(feedback, color: theme.accent) }
                WorkspaceColumns(initial: 280, minimum: 230, maximum: 400, savedWidth: $workspace.restoration.gitBrowserWidth) {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(GitSection.allCases, id: \.self) { section in
                                    let changes = model.snapshot?.changes.filter { $0.section == section } ?? []
                                    if !changes.isEmpty {
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack {
                                                Text(section.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                                                Text("\(changes.count)").font(.caption).foregroundStyle(.tertiary)
                                                Spacer()
                                                Button(section == .staged ? "Unstage All" : "Stage All") { if section == .staged { model.unstage(nil) } else { model.stage(nil) } }.font(.system(size: 9)).disabled(model.operation != nil)
                                            }.foregroundStyle(.secondary).padding(.horizontal, 12)
                                            ForEach(changes) { change in fileRow(change) }
                                        }
                                    }
                                }
                                if model.snapshot?.changes.isEmpty == true {
                                    Label("Working tree clean", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).padding(20)
                                }
                            }.padding(.vertical, 16)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("COMMIT").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                            TextEditor(text: $workspace.restoration.commitDraft).font(.system(size: 12)).scrollContentBackground(.hidden).padding(7)
                                .frame(minHeight: 70, maxHeight: 110).background(theme.background, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .topLeading) { if workspace.restoration.commitDraft.isEmpty { Text("Describe your changes…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(12).allowsHitTesting(false) } }
                                .onChange(of: workspace.restoration.commitDraft) { _, _ in workspace.saveSoon() }
                            Text("Commits include staged changes.").font(.system(size: 10)).foregroundStyle(.tertiary)
                            HStack {
                                Button("Commit") { commit(push: false) }
                                Button("Commit & Push") { commit(push: true) }.buttonStyle(.borderedProminent)
                            }.disabled(!canCommit)
                        }.padding(14)
                    }.background(theme.panel.opacity(0.55))
                } trailing: {
                    VStack(spacing: 0) {
                        if let selected = model.selected {
                            HStack {
                                Text(selected.path).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Picker("Diff layout", selection: $sideBySide) { Text("Unified").tag(false); Text("Split").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                                Button("Open File") { workspace.restoration.selectedFile = workspace.paths.relative((model.snapshot?.root ?? workspace.paths.root).appendingPathComponent(selected.path)); workspace.restoration.selectedTab = "Code"; workspace.restoration.filesVisible = true; workspace.saveSoon() }
                            }.padding(12).background(theme.panel)
                            if let diff = model.diff { DiffContent(preview: diff, sideBySide: sideBySide) }
                            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        } else {
                            VStack(spacing: 13) { Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36, weight: .ultraLight)); Text("Select a changed file to review its diff.").font(.callout) }
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(minWidth: 320)
                }
            }
        }.task { await model.refresh(); if let id = workspace.restoration.selectedDiff, let change = model.snapshot?.changes.first(where: { $0.id == id }) { model.select(change) } }
        .onReceive(NotificationCenter.default.publisher(for: .freemindCommand)) { message in
            guard message.object as? UUID == workspace.id, message.userInfo?["window"] as? Int == windowID else { return }
            switch message.userInfo?["command"] as? String {
            case "commit": if canCommit { commit(push: false) }
            case "commitPush": if canCommit { commit(push: true) }
            case "push": if model.operation == nil { push() }
            default: break
            }
        }
        .onChange(of: model.selected?.id) { _, id in workspace.restoration.selectedDiff = id; workspace.saveSoon() }
        .sheet(isPresented: $pushSetup) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publish branch").font(.title2.bold())
                Text("Choose where to push \(model.snapshot?.branch ?? "this branch"). This also sets its upstream.").foregroundStyle(.secondary)
                if model.snapshot?.remotes.isEmpty == true {
                    Text("No Git remote is configured. Add one with git remote add in a terminal, then refresh this tab.").foregroundStyle(.orange)
                }
                Picker("Remote", selection: $remote) { ForEach(model.snapshot?.remotes ?? [], id: \.self) { Text($0).tag($0) } }
                TextField("Destination branch", text: $branch)
                HStack { Spacer(); Button("Cancel") { pushSetup = false }; Button("Push Branch") {
                    pushSetup = false
                    Task { _ = await model.perform("Pushing…") { try await model.service.push(remote: remote, branch: branch) } }
                }.buttonStyle(.borderedProminent).disabled(remote.isEmpty || branch.isEmpty) }
            }.padding(26).frame(width: 470)
        }
    }
    private var canCommit: Bool { model.operation == nil && !workspace.restoration.commitDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.snapshot?.changes.contains(where: { $0.section == .staged }) == true }
    private var repositoryBar: some View {
        HStack(spacing: 12) {
            GitBranchButton(model: model)
            if let snapshot = model.snapshot {
                Text("↑\(snapshot.ahead) ↓\(snapshot.behind)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).help("Compared with the latest fetched upstream state")
                Text(snapshot.upstream ?? "No upstream").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("+\(snapshot.added)").foregroundStyle(theme.addition); Text("−\(snapshot.deleted)").foregroundStyle(.red.opacity(0.8))
            } else { Spacer() }
            if let operation = model.operation { ProgressView().controlSize(.small); Text(operation).font(.caption) }
            Button { Task { _ = await model.perform("Fetching…") { try await model.service.fetch(); return "Remote state updated" } } } label: { Image(systemName: "arrow.down") }.help("Fetch remotes").disabled(model.operation != nil)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            Button("Push") { push() }.disabled(model.operation != nil || model.snapshot == nil || model.snapshot?.branch == "Detached HEAD")
        }.font(.system(size: 11)).padding(14).background(theme.panel.opacity(0.5)).help(model.snapshot?.root.path ?? workspace.paths.root.path)
    }
    private func fileRow(_ change: GitChange) -> some View {
        HStack(spacing: 9) {
            Text(change.status).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(change.conflicted ? .orange : change.status == "D" ? .red : theme.accent).frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: change.path).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                let folder = (change.path as NSString).deletingLastPathComponent
                if !folder.isEmpty { Text(folder).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 1)
            Button { if change.section == .staged { model.unstage(change) } else { model.stage(change) } } label: { Image(systemName: change.section == .staged ? "minus.circle" : "plus.circle") }.buttonStyle(.borderless).disabled(model.operation != nil).help(change.section == .staged ? "Unstage file" : "Stage file")
        }.padding(.horizontal, 12).padding(.vertical, 8).background(model.selected?.id == change.id ? theme.accent.opacity(0.10) : .clear)
            .contentShape(Rectangle()).onTapGesture { model.select(change) }
    }
    private func message(_ text: String, color: Color) -> some View {
        HStack { Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 11)).lineLimit(4).textSelection(.enabled); Spacer(); Button { model.feedback = nil } label: { Image(systemName: "xmark") } }.foregroundStyle(color).padding(10).background(color.opacity(0.07))
    }
    private func commit(push alsoPush: Bool) {
        let message = workspace.restoration.commitDraft
        Task {
            if await model.perform("Committing…", body: { try await model.service.commit(message) }) {
                workspace.restoration.commitDraft = ""; workspace.saveSoon()
                if alsoPush { push() }
            }
        }
    }
    private func push() {
        if model.snapshot?.upstream == nil {
            remote = model.snapshot?.remotes.first(where: { $0 == "origin" }) ?? model.snapshot?.remotes.first ?? ""
            branch = model.snapshot?.branch ?? ""; pushSetup = true
        } else { Task { _ = await model.perform("Pushing…") { try await model.service.push() } } }
    }
}

struct DiffContent: View {
    @Environment(\.appTheme) private var theme
    let preview: DiffPreview
    let sideBySide: Bool
    var body: some View {
        VStack(spacing: 0) {
            if preview.binary { Label("Binary file — text preview unavailable", systemImage: "doc.zipper").padding(20).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                let textWidth = CGFloat(preview.lines.map { $0.text.utf16.count }.max() ?? 0) * 6.65
                let columnWidth = max(geometry.size.width / 2, textWidth + 70)
                let width = sideBySide ? columnWidth * 2 + 1 : max(geometry.size.width, textWidth + 120)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if sideBySide {
                            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                                HStack(spacing: 0) {
                                    diffRow(pair.0, side: "old").frame(width: columnWidth)
                                    Rectangle().fill(theme.border).frame(width: 1)
                                    diffRow(pair.1, side: "new").frame(width: columnWidth)
                                }.frame(height: 22)
                            }
                        } else { ForEach(preview.lines) { diffRow($0, side: nil).frame(width: width, height: 22) } }
                    }.textSelection(.enabled).frame(width: width, alignment: .topLeading)
                        .frame(minHeight: geometry.size.height, alignment: .topLeading)
                }.defaultScrollAnchor(.topLeading)
            }
            if preview.truncated { Text("Preview limited to 6,000 lines. Open the file to inspect more.").font(.caption).foregroundStyle(.orange).padding(10) }
        }
    }
    private func diffRow(_ line: DiffLine?, side: String?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if side == nil { Text(line?.oldLine.map(String.init) ?? "").frame(width: 42, alignment: .trailing); Text(line?.newLine.map(String.init) ?? "").frame(width: 42, alignment: .trailing) }
            else { Text((side == "old" ? line?.oldLine : line?.newLine).map(String.init) ?? "").frame(width: 42, alignment: .trailing) }
            Text(line?.text ?? " ").lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(line?.kind == "hunk" ? theme.accent : Color.primary.opacity(0.86)).padding(.leading, 16).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).padding(.vertical, 3).padding(.trailing, 12)
            .background(line?.kind == "add" ? theme.addition.opacity(0.13) : line?.kind == "remove" ? Color.red.opacity(0.10) : line?.kind == "hunk" ? Color.primary.opacity(0.04) : .clear)
    }
    private var pairs: [(DiffLine?, DiffLine?)] {
        var result: [(DiffLine?,DiffLine?)] = [], removes: [DiffLine] = [], adds: [DiffLine] = []
        func flush() { for i in 0..<max(removes.count, adds.count) { result.append((i < removes.count ? removes[i] : nil, i < adds.count ? adds[i] : nil)) }; removes = []; adds = [] }
        for line in preview.lines {
            if line.kind == "remove" { removes.append(line) }
            else if line.kind == "add" { adds.append(line) }
            else { flush(); result.append((line,line)) }
        }
        flush(); return result
    }
}
