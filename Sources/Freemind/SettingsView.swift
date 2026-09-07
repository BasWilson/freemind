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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var error: String?
    @State private var editingTheme: ThemeEditingRequest?
    @State private var designingTheme: CustomTheme?
    var body: some View {
        Form {
            Section("App appearance") {
                Picker("Mode", selection: setting(\.appearance)) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Color theme", selection: themeSelection(terminal: false)) { themeChoices(terminal: false) }
                Text("System follows your Mac’s appearance. Changes apply to every Freemind window.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal appearance") {
                Picker("Mode", selection: setting(\.terminalAppearance)) {
                    ForEach(TerminalAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Color theme", selection: themeSelection(terminal: true)) { themeChoices(terminal: true) }
                Text("Choose a separate look for all terminals, including detached windows. Running sessions update immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Window transparency") {
                Toggle("Translucent main window", isOn: setting(\.translucentWindows))
                if store.settings.translucentWindows {
                    HStack {
                        Slider(value: setting(\.windowOpacity), in: 0.65...1, step: 0.01) {
                            Text("Main window opacity")
                        } minimumValueLabel: { Text("65%") } maximumValueLabel: { Text("100%") }
                        Text("\(Int((store.settings.windowOpacity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }.disabled(reduceTransparency)
                }
                Text(reduceTransparency ? "macOS Reduce Transparency is enabled, so windows stay opaque." : "See a softly blurred background behind the main window. Settings and detached workspace and terminal windows stay opaque.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Custom themes") {
                HStack {
                    Button("New Theme…") { editingTheme = ThemeEditingRequest(theme: theme.customCopy(name: newThemeName)) }
                    Menu("Edit Theme") {
                        ForEach(store.customThemes) { custom in
                            Button(custom.name) { editingTheme = ThemeEditingRequest(theme: custom, original: custom) }
                        }
                    }.disabled(store.customThemes.isEmpty)
                    Button("Create with Codex…") { designingTheme = theme.customCopy(name: newThemeName) }
                }
                HStack {
                    Button("Open Theme Configuration") {
                        do { try store.openThemeConfiguration(); openWindow(id: "main"); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    Button("Reload Themes") { store.reloadThemes() }
                }
                Text("Create your own light and dark palettes, or describe a look to Codex. The configuration opens with a guide, and valid saved edits apply automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                ThemePreview(theme: theme, terminalTheme: terminalTheme)
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }.formStyle(.grouped)
        .sheet(item: $editingTheme) { request in CustomThemeEditor(store: store, theme: request.theme, original: request.original) }
        .sheet(item: $designingTheme) { theme in CodexThemeDesigner(store: store, theme: theme) }
    }
    private var newThemeName: String {
        let names = Set(store.customThemes.map { $0.name.lowercased() })
        var name = "My Theme", suffix = 2
        while names.contains(name.lowercased()) { name = "My Theme \(suffix)"; suffix += 1 }
        return name
    }
    @ViewBuilder private func themeChoices(terminal: Bool) -> some View {
        if terminal { Text("Match app").tag("app") }
        ForEach(AppColorTheme.allCases, id: \.self) { Text($0.title).tag("builtin:" + $0.rawValue) }
        if !store.customThemes.isEmpty {
            Divider()
            ForEach(store.customThemes) { Text($0.name + " (Custom)").tag("custom:" + $0.id) }
        }
        let selectedID = terminal ? store.settings.terminalCustomThemeID : store.settings.customThemeID
        if let selectedID, !store.customThemes.contains(where: { $0.id == selectedID }) {
            Text("Missing custom theme").tag("custom:" + selectedID)
        }
    }
    private func themeSelection(terminal: Bool) -> Binding<String> {
        Binding(get: {
            if let id = terminal ? store.settings.terminalCustomThemeID : store.settings.customThemeID { return "custom:" + id }
            if terminal { return store.settings.terminalTheme.map { "builtin:" + $0.rawValue } ?? "app" }
            return "builtin:" + store.settings.theme.rawValue
        }, set: { selection in
            var settings = store.settings
            if terminal { settings.terminalCustomThemeID = nil; settings.terminalTheme = nil }
            else { settings.customThemeID = nil }
            if selection.hasPrefix("custom:"), let custom = store.customThemes.first(where: { $0.id == String(selection.dropFirst(7)) }) {
                if terminal { settings.terminalCustomThemeID = custom.id; settings.terminalTheme = custom.base }
                else { settings.customThemeID = custom.id; settings.theme = custom.base }
            } else if selection.hasPrefix("builtin:"), let base = AppColorTheme(rawValue: String(selection.dropFirst(8))) {
                if terminal { settings.terminalTheme = base } else { settings.theme = base }
            }
            do { try store.saveSettings(settings); error = nil }
            catch { self.error = error.localizedDescription }
        })
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
