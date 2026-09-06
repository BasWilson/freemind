import SwiftUI
import FreemindCore

struct NotesView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var document: EditorDocument
    init(workspace: WorkspaceModel) { self.workspace = workspace; self.document = workspace.notesDocument }
    @State private var notes: [URL] = []
    @State private var search = ""
    @State private var preview = false
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        WorkspaceColumns(initial: 220, minimum: 180, savedWidth: $workspace.restoration.notesBrowserWidth) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("NOTES").font(.system(size: 10, weight: .semibold)).tracking(1); Spacer(); Button { name = ""; creating = true } label: { Image(systemName: "plus") }.help("New note") }.foregroundStyle(.secondary)
                TextField("Search notes…", text: $search).textFieldStyle(.roundedBorder).font(.caption)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(filtered, id: \.path) { url in
                            HStack { Image(systemName: "doc.plaintext").foregroundStyle(theme.accent); Text(url.deletingPathExtension().lastPathComponent).lineLimit(1); Spacer() }
                                .font(.system(size: 12)).padding(10).background(workspace.restoration.selectedNote == url.lastPathComponent ? theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle()).onTapGesture { if document.save() { workspace.restoration.selectedNote = url.lastPathComponent; load(); workspace.saveSoon() } }
                        }
                    }
                }
            }.padding(14).background(theme.panel.opacity(0.5))
        } trailing: {
            VStack(spacing: 0) {
                HStack {
                    Text(workspace.restoration.selectedNote).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(document.dirty ? "Saving…" : "Saved in workspace").font(.caption).foregroundStyle(.tertiary)
                    Picker("Mode", selection: $preview) { Text("Edit").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
                }.padding(14).background(theme.panel)
                if let error = document.error {
                    HStack { Text(error).font(.caption); Spacer(); Button("Save a Copy…") { document.saveCopy() }; Button("Reload") { document.load(workspace.paths.notes.appendingPathComponent(workspace.restoration.selectedNote), force: true) } }.foregroundStyle(.orange).padding(10)
                }
                if preview {
                    ScrollView { MarkdownPreview(text: document.text).frame(maxWidth: .infinity, alignment: .leading).padding(30) }
                } else {
                    NativeCodeEditor(text: $document.text, selection: $document.selection, language: "md", lineNumbers: false, changed: { document.saveSoon() })
                }
            }
        }.task { refresh(); load() }
        .onChange(of: workspace.externalRevision) { _, _ in refresh(); document.externalChange() }
        .onChange(of: document.selection) { _, value in workspace.restoration.notePositions[workspace.restoration.selectedNote] = value.location; workspace.saveSoon() }
        .onDisappear { _ = document.save() }
        .onReceive(NotificationCenter.default.publisher(for: .freemindSave)) { _ in _ = document.save() }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 18) {
                Text("New note").font(.title2.bold()); TextField("Note name", text: $name)
                HStack { Spacer(); Button("Cancel") { creating = false }; Button("Create") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/")) }
            }.padding(26).frame(width: 400)
        }
    }
    var filtered: [URL] {
        if search.isEmpty { return notes }
        return notes.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(search) || ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").localizedCaseInsensitiveContains(search) }
    }
    func refresh() { notes = ((try? FileManager.default.contentsOfDirectory(at: workspace.paths.notes, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    func load() {
        let url = workspace.paths.notes.appendingPathComponent(workspace.restoration.selectedNote)
        document.selection = NSRange(location: workspace.restoration.notePositions[workspace.restoration.selectedNote] ?? 0, length: 0)
        document.load(url)
    }
    func create() {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var file = base.hasSuffix(".md") ? base : base + ".md"
        guard file != ".md", file != "..", !file.contains("/"), document.save() else { return }
        if FileManager.default.fileExists(atPath: workspace.paths.notes.appendingPathComponent(file).path) { file = "\(base)-\(Int(Date().timeIntervalSince1970)).md" }
        do {
            try Data(("# \(base)\n\n").utf8).write(to: workspace.paths.notes.appendingPathComponent(file), options: .atomic)
            workspace.restoration.selectedNote = file; workspace.saveSoon(); creating = false; refresh(); load()
        } catch { document.error = error.localizedDescription }
    }
}

struct MarkdownPreview: View {
    @Environment(\.appTheme) private var theme
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code { Text(block.text).font(.system(size: 12, design: .monospaced)).padding(15).frame(maxWidth: .infinity, alignment: .leading).background(theme.panel, in: RoundedRectangle(cornerRadius: 8)) }
                else if block.text.hasPrefix("# ") { Text(String(block.text.dropFirst(2))).font(.largeTitle.bold()).padding(.top, 10) }
                else if block.text.hasPrefix("## ") { Text(String(block.text.dropFirst(3))).font(.title2.bold()).padding(.top, 7) }
                else if block.text.hasPrefix("### ") { Text(String(block.text.dropFirst(4))).font(.headline) }
                else { Text((try? AttributedString(markdown: block.text)) ?? AttributedString(block.text)).font(.system(size: 14)).lineSpacing(5) }
            }
        }.textSelection(.enabled)
    }
    var blocks: [(text: String, code: Bool)] {
        var result: [(String,Bool)] = [], code = false, buffer = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { if !buffer.isEmpty { result.append((buffer,code)); buffer = "" }; code.toggle() }
            else if code { buffer += (buffer.isEmpty ? "" : "\n") + line }
            else if line.isEmpty { if !buffer.isEmpty { result.append((buffer,false)); buffer = "" } }
            else if line.hasPrefix("#") { if !buffer.isEmpty { result.append((buffer,false)); buffer = "" }; result.append((line,false)) }
            else { buffer += (buffer.isEmpty ? "" : "\n") + line }
        }
        if !buffer.isEmpty { result.append((buffer,code)) }; return result
    }
}
