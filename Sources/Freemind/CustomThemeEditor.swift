import SwiftUI
import AppKit
import FreemindCore

struct ThemeEditingRequest: Identifiable {
    var theme: CustomTheme
    var original: CustomTheme?
    var id: String { theme.id }
}

struct CustomThemeEditor: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomTheme
    @State private var original: CustomTheme?
    @State private var dark = true
    @State private var error: String?

    init(store: AppStore, theme: CustomTheme, original: CustomTheme?) {
        self.store = store; _draft = State(initialValue: theme); _original = State(initialValue: original)
    }
    private var preview: Theme { Theme(style: draft.base, isDark: dark, custom: draft) }
    private var variant: Binding<CustomThemeVariant> {
        Binding(get: { dark ? draft.dark : draft.light }, set: { if dark { draft.dark = $0 } else { draft.light = $0 } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "Create a theme" : "Edit theme").font(.title2.bold())
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Base palette", selection: $draft.base) { ForEach(AppColorTheme.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("Colors you leave unchanged follow the base palette.").font(.caption).foregroundStyle(.secondary)
                    Picker("Editing", selection: $dark) { Text("Light").tag(false); Text("Dark").tag(true) }.pickerStyle(.segmented)
                }
                Section("Preview") { ThemePreview(theme: preview, terminalTheme: preview) }
                Section("Colors") {
                    ForEach(ThemeColorRole.allCases, id: \.self) { role in
                        colorRow(role.title, value: Binding(get: {
                            variant.wrappedValue.colors[role.rawValue] ?? ThemeHex.string(preview.hex(for: role))
                        }, set: { variant.wrappedValue.colors[role.rawValue] = $0 }), fallback: preview.hex(for: role))
                    }
                }
                Section {
                    DisclosureGroup("Terminal ANSI colors") {
                        ForEach(0..<16, id: \.self) { index in
                            colorRow(Self.ansiNames[index], value: Binding(get: {
                                variant.wrappedValue.ansiColors?[index] ?? ThemeHex.string(preview.ansiColors[index])
                            }, set: { value in
                                var colors = variant.wrappedValue.ansiColors ?? preview.ansiColors.map(ThemeHex.string)
                                colors[index] = value; variant.wrappedValue.ansiColors = colors
                            }), fallback: preview.ansiColors[index])
                        }
                    }
                    Button("Reset \(dark ? "Dark" : "Light") Colors to Base") { variant.wrappedValue = .init() }
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("Save applies the theme to the app.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Use") {
                    do {
                        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        try store.saveCustomTheme(draft, replacing: original); original = draft
                        try store.useCustomTheme(draft); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: 740)
    }

    private func colorRow(_ title: String, value: Binding<String>, fallback: UInt32) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("#RRGGBB", text: value).font(.system(size: 12, design: .monospaced)).frame(width: 92)
                .accessibilityLabel(title + " hex color")
            ColorPicker(title, selection: Binding(get: {
                Color(nsColor: Theme.color(ThemeHex.parse(value.wrappedValue) ?? fallback))
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, (value * 255).rounded()))) }
                value.wrappedValue = ThemeHex.string(channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent))
            }), supportsOpacity: false).labelsHidden()
        }
    }
    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                                    "Bright black", "Bright red", "Bright green", "Bright yellow", "Bright blue", "Bright magenta", "Bright cyan", "Bright white"]
}

struct CodexThemeDesigner: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var draft: CustomTheme
    @State private var original: CustomTheme?
    @State private var request = ""
    @State private var error: String?
    init(store: AppStore, theme: CustomTheme) { self.store = store; _draft = State(initialValue: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a theme with Codex").font(.title2.bold())
            TextField("Theme name", text: $draft.name)
            Text("Describe the look you want").font(.headline)
            TextEditor(text: $request).font(.body).frame(height: 130)
                .overlay(alignment: .topLeading) {
                    if request.isEmpty { Text("For example: warm charcoal, soft amber accents, and gentle syntax colors.").foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
                }
            Text("A new Codex terminal opens in your Themes workspace with the configuration, editing guide, and this description. The new theme is selected, so valid saved changes appear immediately.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Codex") {
                    do {
                        _ = try TerminalBackend.resolveCodex(store.settings.workspaceDefaults.executable, environment: store.environment)
                        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        try store.saveCustomTheme(draft, replacing: original); original = draft
                        try store.useCustomTheme(draft)
                        try store.openThemeConfiguration(prompt: CustomThemeConfiguration.codexPrompt(theme: draft, request: request))
                        openWindow(id: "main"); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
    }
}

struct ThemePreview: View {
    var theme: Theme
    var terminalTheme: Theme
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "leaf.fill").foregroundStyle(theme.accent)
                Text("Your workspace").fontWeight(.medium)
                Spacer()
                Text("Code   Git   Notes").foregroundStyle(Color(nsColor: theme.nativeMuted))
            }.padding(14).background(theme.panel)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sources", systemImage: "folder").foregroundStyle(theme.accent)
                    Label("Notes.md", systemImage: "doc.text")
                    Text("// your next idea").foregroundStyle(Color(nsColor: theme.nativeMuted))
                }.font(.caption).padding(16).frame(maxHeight: .infinity, alignment: .top).background(theme.background)
                VStack(alignment: .leading, spacing: 10) {
                    Text("❯ freemind").foregroundStyle(Color(nsColor: terminalTheme.nativeAccent))
                    Text("Ready for your next idea.").foregroundStyle(Color(nsColor: terminalTheme.nativeText))
                    HStack(spacing: 12) {
                        Text("added").foregroundStyle(Color(nsColor: Theme.color(terminalTheme.ansiColors[2])))
                        Text("modified").foregroundStyle(Color(nsColor: Theme.color(terminalTheme.ansiColors[3])))
                        Text("deleted").foregroundStyle(Color(nsColor: Theme.color(terminalTheme.ansiColors[1])))
                    }
                    HStack(spacing: 0) {
                        Text("let ").foregroundStyle(Color(nsColor: theme.keyword))
                        Text("idea = ").foregroundStyle(Color(nsColor: theme.nativeText))
                        Text("\"Hello\"").foregroundStyle(Color(nsColor: theme.string))
                    }
                }.font(.system(size: 12, design: .monospaced)).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: terminalTheme.nativeCanvas))
            }.frame(height: 130)
        }.foregroundStyle(Color(nsColor: theme.nativeText)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border))
    }
}
