import SwiftUI
import AppKit
import FreemindCore

struct FileEntry: Identifiable { let url: URL; let directory: Bool; var id: String { url.path } }
enum FileListing {
    static func children(_ folder: URL, hidden: Bool) -> [FileEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: hidden ? [] : [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.lastPathComponent != ".git" && !($0.lastPathComponent == "local" && folder.lastPathComponent == ".freemind") }
            .map { url in let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]); return FileEntry(url: url, directory: values?.isDirectory == true && values?.isSymbolicLink != true) }
            .sorted { if $0.directory != $1.directory { return $0.directory }; return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
    static func search(_ root: URL, query: String, hidden: Bool) -> [FileEntry] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: hidden ? [] : [.skipsHiddenFiles]) else { return [] }
        var results: [FileEntry] = []
        for case let url as URL in files {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir && [".git", "node_modules", ".build", "local"].contains(url.lastPathComponent) { files.skipDescendants(); continue }
            if !isDir && url.path.localizedCaseInsensitiveContains(query) { results.append(FileEntry(url: url, directory: false)); if results.count >= 200 { break } }
        }
        return results
    }
}

struct FilesPanel: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    @State private var hidden = false
    @State private var query = ""
    @State private var entries: [FileEntry] = []
    @State private var comments = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FILES").font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Menu { Toggle("Show Hidden Files", isOn: $hidden); Button("Refresh") { refresh() }; Button("Workspace Comments (\(workspace.comments.count))") { comments = true } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.foregroundStyle(.secondary).padding(13)
            TextField("Find files…", text: $query).textFieldStyle(.roundedBorder).font(.caption).padding(.horizontal, 10).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { entry in FileRow(workspace: workspace, entry: entry, hidden: hidden, depth: 0, showPath: !query.isEmpty) }
                    if entries.count == 200 && !query.isEmpty { Text("First 200 matches").font(.caption).foregroundStyle(.tertiary).padding() }
                }.padding(.horizontal, 5)
            }
        }.background(theme.panel.opacity(0.5)).task { refresh() }
        .onChange(of: query) { _, _ in refresh() }.onChange(of: hidden) { _, _ in refresh() }
        .onChange(of: workspace.externalRevision) { _, _ in refresh() }
        .sheet(isPresented: $comments) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Workspace comments").font(.title2.bold())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(workspace.comments) { comment in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(comment.file):\(comment.startLine)–\(comment.endLine)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.accent)
                                Text(comment.comment).textSelection(.enabled)
                                HStack {
                                    Button("Open File") { workspace.restoration.selectedFile = comment.file; comments = false }
                                    Button("Start Another Codex Pane") { workspace.addPane(title: "Review · " + URL(fileURLWithPath: comment.file).lastPathComponent, prompt: comment.prompt); comments = false }
                                }.font(.caption)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if workspace.comments.isEmpty { Text("Select code in a file and add a comment to start a review.").foregroundStyle(.secondary) }
                    }
                }
                Button("Done") { comments = false }
            }.padding(24).frame(width: 620, height: 600)
        }
    }
    private func refresh() {
        let q = query, h = hidden, root = workspace.paths.root
        Task { let values = await Task.detached { q.isEmpty ? FileListing.children(root, hidden: h) : FileListing.search(root, query: q, hidden: h) }.value; if query == q { entries = values } }
    }
}

struct FileRow: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    let entry: FileEntry
    let hidden: Bool
    let depth: Int
    var showPath = false
    @State private var expanded = false
    @State private var children: [FileEntry] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: entry.directory ? (expanded ? "chevron.down" : "chevron.right") : "").font(.system(size: 8)).frame(width: 9)
                Image(systemName: entry.directory ? (expanded ? "folder.fill" : "folder") : icon).font(.system(size: 11)).foregroundStyle(entry.directory ? theme.accent.opacity(0.8) : .secondary)
                Text(showPath ? workspace.paths.relative(entry.url) : entry.url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.padding(.leading, CGFloat(depth) * 12 + 6).padding(.trailing, 8).padding(.vertical, 6)
                .background(workspace.restoration.selectedFile == workspace.paths.relative(entry.url) ? theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle()).onTapGesture {
                    if entry.directory { expanded.toggle(); if expanded { refresh() } }
                    else { workspace.restoration.selectedFile = workspace.paths.relative(entry.url); workspace.saveSoon() }
                }.onDrag {
                    let provider = NSItemProvider()
                    provider.suggestedName = entry.url.lastPathComponent
                    provider.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
                        completion(entry.url.dataRepresentation, nil); return nil
                    }
                    return provider
                }
                .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }; if !entry.directory { Button("Open Externally") { NSWorkspace.shared.open(entry.url) } } }
            if expanded { ForEach(children) { child in AnyView(FileRow(workspace: workspace, entry: child, hidden: hidden, depth: depth + 1)) } }
        }.onChange(of: hidden) { _, _ in if expanded { refresh() } }.onChange(of: workspace.externalRevision) { _, _ in if expanded { refresh() } }
    }
    var icon: String { ["swift","js","ts","tsx","jsx","py","rs","go","html","css","json"].contains(entry.url.pathExtension) ? "chevron.left.forwardslash.chevron.right" : "doc.text" }
    func refresh() { let folder = entry.url, h = hidden; Task { children = await Task.detached { FileListing.children(folder, hidden: h) }.value } }
}

struct CodeEditorPanel: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.workspaceWindowID) private var windowID
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var document: EditorDocument
    init(workspace: WorkspaceModel) { self.workspace = workspace; self.document = workspace.codeDocument }
    @State private var commenting = false
    @State private var commentText = ""
    @State private var selectedCode = ""
    @State private var firstLine = 1
    @State private var lastLine = 1
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(theme.accent)
                Text(workspace.restoration.selectedFile ?? "").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if document.dirty { Circle().fill(.orange).frame(width: 5, height: 5) }
                Spacer()
                Button("Save") { _ = document.save() }.disabled(!document.dirty).keyboardShortcut("s")
                Button { beginComment() } label: { Label("Comment → Codex", systemImage: "text.bubble") }.disabled(document.baseline == nil)
                Button { workspace.closeFile() } label: { Image(systemName: "xmark") }.help("Close file")
            }.buttonStyle(.borderless).font(.system(size: 11)).padding(12).background(theme.panel)
            if let error = document.error {
                HStack { Text(error).font(.caption); Spacer(); Button("Reload") { if let url = document.url { document.load(url, force: true) } }; Button("Save a Copy…") { document.saveCopy() }; Button("Open Externally") { if let url = document.url { NSWorkspace.shared.open(url) } } }.foregroundStyle(.orange).padding(10)
            }
            NativeCodeEditor(text: $document.text, selection: $document.selection, language: document.url?.pathExtension ?? "txt", changed: { document.changed() })
            HStack { Text(document.url?.pathExtension.uppercased() ?? "TEXT"); Spacer(); Text("Select lines, then add a comment to ask Codex for a change.") }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(7)
        }.onAppear { loadSelected() }
        .onDisappear { _ = document.save() }
        .onChange(of: workspace.restoration.selectedFile) { _, _ in loadSelected() }
        .onChange(of: workspace.externalRevision) { _, _ in document.externalChange() }
        .onChange(of: document.selection) { _, range in workspace.restoration.editorPosition = range.location; workspace.saveSoon() }
        .onReceive(NotificationCenter.default.publisher(for: .freemindCommand)) { message in
            if message.object as? UUID == workspace.id, message.userInfo?["command"] as? String == "comment", message.userInfo?["window"] as? Int == windowID { beginComment() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .freemindSave)) { _ in _ = document.save() }
        .sheet(isPresented: $commenting) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Ask Codex to change this code").font(.title2.bold())
                Text("\(workspace.restoration.selectedFile ?? "") · lines \(firstLine)–\(lastLine)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.accent)
                ScrollView { Text(selectedCode).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 190).padding(12).background(theme.background, in: RoundedRectangle(cornerRadius: 8))
                Text("What should change?").font(.headline)
                TextEditor(text: $commentText).font(.system(size: 13)).frame(height: 130).padding(8).background(theme.background)
                Text("A new Codex terminal will receive this comment, file path, and selected code. The comment is saved in your workspace.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { commenting = false }; Button("Start Codex") {
                    let comment = CodeComment(file: workspace.restoration.selectedFile ?? "", startLine: firstLine, endLine: lastLine, selection: selectedCode, comment: commentText)
                    workspace.submit(comment); commenting = false; commentText = ""
                }.buttonStyle(.borderedProminent).disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 650)
        }
    }
    func loadSelected() {
        guard let selected = workspace.restoration.selectedFile else { return }
        if document.dirty && !document.save() {
            if let url = document.url { workspace.restoration.selectedFile = workspace.paths.relative(url) }; return
        }
        document.selection = NSRange(location: workspace.restoration.editorPosition, length: 0)
        document.load(workspace.paths.resolve(selected))
    }
    func beginComment() {
        guard document.save() else { return }
        let text = document.text as NSString
        let range = NSRange(location: min(document.selection.location, text.length), length: min(document.selection.length, max(0, text.length - document.selection.location)))
        let selection = range.length == 0 ? text.lineRange(for: range) : range
        selectedCode = text.substring(with: selection)
        firstLine = text.substring(to: selection.location).components(separatedBy: "\n").count
        lastLine = firstLine + selectedCode.trimmingCharacters(in: .newlines).components(separatedBy: "\n").count - 1
        commenting = true
    }
}
extension Notification.Name { static let freemindSave = Notification.Name("FreemindSaveDocuments") }
