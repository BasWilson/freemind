import SwiftUI
import FreemindCore

struct NewPaneSheet: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var workspace: WorkspaceModel
    var defaultsOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var options = CodexOptions()
    @State private var kind = PaneKind.codex
    @State private var title = ""
    @State private var useAsDefaults = false
    @State private var helpText: String?
    @State private var error: String?
    @State private var checking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "terminal.fill").foregroundStyle(theme.accent).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(defaultsOnly ? "Terminal defaults" : "New terminal").font(.title2.bold())
                    Text(workspace.definition.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("CLI Help") { inspectHelp() }.disabled(checking)
            }
            if defaultsOnly { Text("Used for new terminals in this workspace. Use Global Defaults to copy your current app settings.").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                Form {
                    if !defaultsOnly {
                        Picker("Type", selection: $kind) { Text("Codex").tag(PaneKind.codex); Text("Shell").tag(PaneKind.shell) }.pickerStyle(.segmented)
                        TextField("Pane title", text: $title, prompt: Text("Automatic"))
                    }
                    if kind == .codex || defaultsOnly {
                        CodexOptionsFields(options: $options)
                    }
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                if defaultsOnly { Button("Use Global Defaults") { options = AppStore.shared.settings.workspaceDefaults } }
                if !defaultsOnly { Toggle("Save as workspace defaults", isOn: $useAsDefaults).toggleStyle(.checkbox) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(defaultsOnly ? "Save Defaults" : "Create Terminal") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620, height: 740).tint(theme.accent)
        .onAppear { options = workspace.definition.defaults }
        .sheet(isPresented: Binding(get: { helpText != nil }, set: { if !$0 { helpText = nil } })) {
            VStack(alignment: .leading) {
                Text("Installed Codex CLI options").font(.headline)
                ScrollView([.horizontal, .vertical]) { Text(helpText ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { helpText = nil }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 800, height: 650)
        }
    }
    private func create() {
        do {
            _ = try options.arguments()
            if useAsDefaults || defaultsOnly {
                let previous = workspace.definition.defaults
                workspace.definition.defaults = options
                guard workspace.saveNow() else { workspace.definition.defaults = previous; error = workspace.error; return }
            }
            if !defaultsOnly { guard workspace.addPane(kind: kind, title: title.isEmpty ? nil : title, options: options) != nil else { error = workspace.error; return } }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func inspectHelp() {
        checking = true
        Task {
            do {
                let environment = await workspace.backend.environment
                let exe = try TerminalBackend.resolveCodex(options.executable, environment: environment)
                let result = try await CommandRunner.run(exe, ["--help"], environment: environment).checked()
                helpText = result.output
            } catch { self.error = error.localizedDescription }
            checking = false
        }
    }
}
