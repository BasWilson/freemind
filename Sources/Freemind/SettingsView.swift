import SwiftUI
import FreemindCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        TabView {
            AppearanceSettingsView(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            WorkspaceDefaultsSettingsView(store: store)
                .tabItem { Label("Workspace Defaults", systemImage: "terminal") }
            Form {
                Section("Freemind") {
                    Text("A local workspace for Codex, your code, and Git.")
                    Text("Quitting keeps terminals running. Use Quit and Stop Terminals to end them.").foregroundStyle(.secondary)
                    Button("Open Workspace…") { store.pickFolder() }
                }
                Section("Updates") { UpdateSettingsView() }
            }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
        }.padding(16).frame(width: 680, height: 740)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.terminalTheme) private var terminalTheme
    @State private var error: String?
    var body: some View {
        Form {
            Section("App appearance") {
                Picker("Mode", selection: setting(\.appearance)) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Color theme", selection: setting(\.theme)) {
                    ForEach(AppColorTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("System follows your Mac’s appearance. Changes apply to every Freemind window.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal appearance") {
                Picker("Mode", selection: setting(\.terminalAppearance)) {
                    ForEach(TerminalAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Color theme", selection: setting(\.terminalTheme)) {
                    Text("Match app").tag(AppColorTheme?.none)
                    ForEach(AppColorTheme.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Text("Choose a separate look for all terminals, including detached windows. Running sessions update immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "leaf.fill").foregroundStyle(theme.accent)
                        Text("Your workspace").fontWeight(.medium)
                        Spacer()
                        Text("Code   Git   Notes").foregroundStyle(.secondary)
                    }.padding(14).background(theme.panel)
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Sources", systemImage: "folder").foregroundStyle(theme.accent)
                            Label("Notes.md", systemImage: "doc.text")
                        }.font(.caption).padding(16).frame(maxHeight: .infinity, alignment: .top).background(theme.background)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("❯ freemind").foregroundStyle(Color(nsColor: terminalTheme.nativeAccent))
                            Text("Ready for your next idea.").foregroundStyle(Color(nsColor: terminalTheme.nativeText))
                            HStack(spacing: 12) {
                                Text("added").foregroundStyle(Color(nsColor: Theme.color(terminalTheme.ansiColors[2])))
                                Text("modified").foregroundStyle(Color(nsColor: Theme.color(terminalTheme.ansiColors[3])))
                                Text("deleted").foregroundStyle(Color(nsColor: Theme.color(terminalTheme.ansiColors[1])))
                            }
                            Text("▍").foregroundStyle(Color(nsColor: terminalTheme.nativeAccent))
                        }.font(.system(size: 12, design: .monospaced)).padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: terminalTheme.nativeCanvas))
                    }.frame(height: 126)
                }.clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border))
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }.formStyle(.grouped)
    }
    private func setting<Value>(_ key: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: key] }, set: { value in
            var settings = store.settings; settings[keyPath: key] = value
            do { try store.saveSettings(settings); error = nil }
            catch { self.error = error.localizedDescription }
        })
    }
}

struct WorkspaceDefaultsSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var options = CodexOptions()
    @State private var error: String?
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Global workspace defaults").font(.title2.bold())
            Text("New workspaces start with these terminal options. Existing workspaces keep their saved settings; use Use Global Defaults in their Terminal Defaults menu to copy these options.").font(.callout).foregroundStyle(.secondary)
            ScrollView { Form { CodexOptionsFields(options: $options) }.formStyle(.grouped) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Reset to Built-in Defaults") { options = CodexOptions(); saved = false }
                Spacer()
                if saved { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                Button("Save Defaults") {
                    var settings = store.settings; settings.workspaceDefaults = options
                    do { try store.saveSettings(settings); error = nil; saved = true }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(16)
            .onAppear { options = store.settings.workspaceDefaults }
            .onChange(of: options) { _, _ in saved = false; error = nil }
    }
}
