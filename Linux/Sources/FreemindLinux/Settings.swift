import Foundation
import FreemindCore
import LinuxUI

extension Controller {
    func loadSettings() async throws {
        settings = try AppSettings.load(from: settingsURL)
        savedSettings = try? Data(contentsOf: settingsURL)
        settingsLoaded = true
        defaultsDraft = settings.workspaceDefaults
        do { try await reloadThemes() }
        catch {
            observedThemes = try? Data(contentsOf: themesURL)
            await applyAppearance()
            await onUI { fm_error(error.localizedDescription) }
        }
        await onUI { Task.detached { await controller.handle("system-appearance", value: String(fm_system_dark())) } }
        await updater.start(configFolder: configFolder)
    }

    func handleSettings(_ action: String, value: String) async throws -> Bool {
        switch action {
        case "settings":
            if defaultsScope == "new" { defaultsScope = "global" }
            if !settingsLoaded { try await loadSettings() }
            defaultsDraft = defaultsScope == "workspace" ? definition?.defaults ?? settings.workspaceDefaults : settings.workspaceDefaults
            try await showSettings()
        case "system-appearance":
            dark = await withCheckedContinuation { continuation in fm_post({ context in
                let box = Unmanaged<AppearanceReply>.fromOpaque(context!).takeRetainedValue()
                box.reply(fm_system_dark() != 0)
            }, Unmanaged.passRetained(AppearanceReply { continuation.resume(returning: $0) }).toOpaque()) }
            await applyAppearance()
        case "setting":
            guard let split = value.firstIndex(of: "\n") else { return true }
            try await changeSetting(String(value[..<split]), String(value[value.index(after: split)...]))
        case "defaults-save":
            _ = try defaultsDraft.arguments()
            if defaultsScope == "workspace" {
                guard let paths, var updated = definition else { throw FreemindError.message("Open a workspace first.") }
                guard (try? Data(contentsOf: paths.definition)) == savedDefinition else { throw FreemindError.message("Workspace defaults changed on disk. Reopen the workspace before saving.") }
                updated.defaults = defaultsDraft
                try DurableFile.save(updated, to: paths.definition)
                definition = updated; savedDefinition = try Data(contentsOf: paths.definition)
            } else {
                var updated = settings; updated.workspaceDefaults = defaultsDraft
                try saveSettings(updated)
            }
            await onUI { fm_settings_message("Defaults saved. New terminals use these options; running terminals keep theirs.", 0) }
        case "defaults-reset", "defaults-global":
            defaultsDraft = action == "defaults-global" ? settings.workspaceDefaults : CodexOptions()
            try await showSettings(page: "defaults")
            await onUI { fm_settings_message("Review the options, then Save Defaults to apply them.", 0) }
        case "themes-reload": try await reloadThemes(); try await showSettings(page: "themes")
        case "themes-save":
            let configuration = try JSONDecoder().decode(CustomThemeConfiguration.self, from: Data(themeJSON.utf8))
            try configuration.save(to: themesURL, expected: savedThemes)
            try await reloadThemes(); try await showSettings(page: "themes")
            await onUI { fm_settings_message("Themes saved and applied.", 0) }
        case "theme-new":
            let current = themes.themes.first { $0.id == settings.customThemeID }
            var suffix = 1, name = "My Theme"
            while themes.themes.contains(where: { $0.name.lowercased() == name.lowercased() }) { suffix += 1; name = "My Theme \(suffix)" }
            themeDraft = ThemeColors(style: settings.theme, custom: current).customCopy(name: name)
            try await showSettings(page: "themes")
        case "theme-reset":
            if themeVariant == "dark" { themeDraft?.dark = .init() } else { themeDraft?.light = .init() }
            try await showSettings(page: "themes")
        case "theme-save":
            try await saveThemeDraft(); try await showSettings(page: "themes")
        case "theme-design":
            guard !themeRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FreemindError.message("Describe the theme you want first.") }
            _ = try TerminalBackend.resolveCodex(settings.workspaceDefaults.executable, environment: environment)
            try await saveThemeDraft()
            guard let themeDraft else { return true }
            try await prepareThemesFolder()
            try await open(themesURL.deletingLastPathComponent().path)
            let pane = PaneDefinition(title: "Theme designer", options: settings.workspaceDefaults)
            var updated = layout; updated.panes.append(pane); updated.automatic = true
            if let tree = updated.tree { updated.tree = .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: tree, second: .pane(pane.id)) }
            else { updated.tree = .pane(pane.id) }
            try save(updated)
            guard let backend else { return true }
            try await backend.start(pane, initialPrompt: CustomThemeConfiguration.codexPrompt(theme: themeDraft, request: themeRequest))
            try await attach(pane)
        case "themes-open":
            try await prepareThemesFolder()
            let uri = themesURL.absoluteString
            await onUI { fm_open_uri(uri) }
        case "update-check", "update-download": await updater.request(download: action == "update-download")
        default: return false
        }
        return true
    }

    func saveSettings(_ updated: AppSettings) throws {
        guard settingsLoaded else { throw FreemindError.message("Reload settings before saving.") }
        guard (try? Data(contentsOf: settingsURL)) == savedSettings else { throw FreemindError.message("Settings changed on disk. Reopen Freemind to load your other edits before saving.") }
        try updated.save(to: settingsURL)
        settings = updated; savedSettings = try Data(contentsOf: settingsURL)
    }

    func changeSetting(_ key: String, _ value: String) async throws {
        if key == "pane.kind" { paneKind = PaneKind(rawValue: value) ?? .codex; return }
        if key == "pane.title" { paneTitle = value; return }
        if key == "pane.defaults" { paneSaveDefaults = value == "true"; return }
        if key == "defaultsScope" {
            defaultsScope = value == "workspace" && paths != nil ? "workspace" : "global"
            defaultsDraft = defaultsScope == "workspace" ? definition!.defaults : settings.workspaceDefaults
            try await showSettings(page: "defaults"); return
        }
        if key.hasPrefix("options.") {
            switch String(key.dropFirst(8)) {
            case "executable": defaultsDraft.executable = value
            case "model": defaultsDraft.model = value
            case "profile": defaultsDraft.profile = value
            case "reasoning": defaultsDraft.reasoning = value
            case "sandbox": defaultsDraft.sandbox = value
            case "approval": defaultsDraft.approval = value
            case "localProvider": defaultsDraft.localProvider = value
            case "additionalDirectories": defaultsDraft.additionalDirectories = value.components(separatedBy: .newlines)
            case "configOverrides": defaultsDraft.configOverrides = value.components(separatedBy: .newlines)
            case "extraArguments": defaultsDraft.extraArguments = value
            case "webSearch": defaultsDraft.webSearch = value == "true"
            case "inline": defaultsDraft.inline = value == "true"
            case "hooks": defaultsDraft.hooks = value == "true"
            case "trustWorkspace": defaultsDraft.automaticallyTrustWorkspace = value == "true"
            default: break
            }
            await onUI { fm_settings_message("Unsaved defaults — Save Defaults applies them to new terminals.", 0) }; return
        }
        if key == "themesJSON" { themeJSON = value; return }
        if key == "themeRequest" { themeRequest = value; return }
        if key == "editTheme" {
            themeDraft = themes.themes.first { $0.id == value }
            try await showSettings(page: "themes"); return
        }
        if key == "themeVariant" { themeVariant = value; try await showSettings(page: "themes"); return }
        if key.hasPrefix("theme.") {
            guard var draft = themeDraft else { return }
            let field = String(key.dropFirst(6))
            if field == "name" { draft.name = value }
            else if field == "base", let base = AppColorTheme(rawValue: value) { draft.base = base }
            else {
                var variant = themeVariant == "dark" ? draft.dark : draft.light
                if field == "ansi" { variant.ansiColors = value.isEmpty ? nil : value.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                else if ThemeColorRole(rawValue: field) != nil { variant.colors[field] = value.isEmpty ? nil : value }
                if themeVariant == "dark" { draft.dark = variant } else { draft.light = variant }
            }
            themeDraft = draft; return
        }
        if key.hasPrefix("updates.") { try await updater.preference(key: String(key.dropFirst(8)), enabled: value == "true"); return }
        var updated = settings
        switch key {
        case "appearance": updated.appearance = AppAppearance(rawValue: value) ?? .system
        case "terminalAppearance": updated.terminalAppearance = TerminalAppearance(rawValue: value) ?? .app
        case "translucentWindows": updated.translucentWindows = value == "true"
        case "windowOpacity": updated.windowOpacity = (Double(value) ?? 90) / 100
        case "theme", "terminalTheme":
            let terminal = key == "terminalTheme"
            if terminal { updated.terminalTheme = nil; updated.terminalCustomThemeID = nil } else { updated.customThemeID = nil }
            if value.hasPrefix("custom:"), let custom = themes.themes.first(where: { $0.id == String(value.dropFirst(7)) }) {
                if terminal { updated.terminalTheme = custom.base; updated.terminalCustomThemeID = custom.id }
                else { updated.theme = custom.base; updated.customThemeID = custom.id }
            } else if let base = AppColorTheme(rawValue: String(value.dropFirst(8))) {
                if terminal { updated.terminalTheme = base } else { updated.theme = base }
            }
        default: return
        }
        try saveSettings(updated); await applyAppearance()
        await onUI { fm_settings_message("Appearance saved. Running terminals have been updated.", 0) }
    }

    func reloadThemes() async throws {
        let loaded = try CustomThemeConfiguration.read(from: themesURL)
        themes = loaded.configuration; savedThemes = loaded.data; observedThemes = loaded.data
        themeJSON = String(data: try DurableFile.encoder.encode(themes), encoding: .utf8)!
        await applyAppearance()
    }
    func pollThemes() async throws {
        let data = try? Data(contentsOf: themesURL)
        guard data != observedThemes else { return }
        observedThemes = data
        // Invalid external edits retain the last working colors and report once.
        try await reloadThemes()
    }
    func prepareThemesFolder() async throws {
        let folder = themesURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: themesURL.path) { try themes.save(to: themesURL, expected: nil); try await reloadThemes() }
        let guide = folder.appendingPathComponent("THEMES.md")
        if !FileManager.default.fileExists(atPath: guide.path) { try CustomThemeConfiguration.instructions.write(to: guide, atomically: true, encoding: .utf8) }
    }
    func saveThemeDraft() async throws {
        guard var draft = themeDraft else { throw FreemindError.message("Create or choose a theme first.") }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = themes
        if let index = updated.themes.firstIndex(where: { $0.id == draft.id }) { updated.themes[index] = draft } else { updated.themes.append(draft) }
        try updated.save(to: themesURL, expected: savedThemes)
        try await reloadThemes(); themeDraft = draft
        var appearance = settings; appearance.customThemeID = draft.id; appearance.theme = draft.base
        try saveSettings(appearance); await applyAppearance()
    }
    func applyAppearance() async {
        let appDark = settings.appearance == .dark || (settings.appearance == .system && dark)
        let appCustom = themes.themes.first { $0.id == settings.customThemeID }
        let terminalCustom = settings.terminalCustomThemeID != nil ? themes.themes.first { $0.id == settings.terminalCustomThemeID } : (settings.terminalTheme == nil ? appCustom : nil)
        let app = ThemeColors(style: settings.theme, isDark: appDark, custom: appCustom)
        let terminal = ThemeColors(style: settings.terminalTheme ?? settings.theme,
                                   isDark: settings.terminalAppearance == .dark || (settings.terminalAppearance == .app && appDark), custom: terminalCustom)
        func hex(_ role: ThemeColorRole) -> String { ThemeHex.string(app.hex(for: role)) }
        let css = """
        @define-color fm_bg \(hex(.background)); @define-color fm_panel \(hex(.panel));
        @define-color fm_canvas \(hex(.canvas)); @define-color fm_text \(hex(.text));
        @define-color fm_accent \(hex(.accent)); @define-color fm_muted \(hex(.muted));
        @define-color fm_border mix(\(hex(.panel)), \(hex(.text)), 0.18);
        @define-color fm_selection mix(\(hex(.panel)), \(hex(.accent)), 0.16);
        @define-color fm_on_accent \(appDark ? "#101813" : "#ffffff");
        @define-color fm_warning \(ThemeHex.string(app.ansiColors[3]));
        @define-color fm_danger \(ThemeHex.string(app.ansiColors[1]));
        @define-color fm_terminal_canvas \(ThemeHex.string(terminal.hex(for: .canvas)));
        """
        let canvas = terminal.hex(for: .canvas), accent = terminal.hex(for: .accent)
        let selection = (0...2).reduce(UInt32(0)) { sum, channel in
            let shift = channel * 8
            return sum | (UInt32(Double((canvas >> shift) & 255) * 0.75 + Double((accent >> shift) & 255) * 0.25) << shift)
        }
        let colors = ([terminal.hex(for: .text), canvas, accent, selection] + terminal.ansiColors).map(ThemeHex.string).joined(separator: "\n")
        let opacity = settings.effectiveWindowOpacity(reduceTransparency: false)
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <style-scheme id="freemind" name="Freemind" version="1.0">
        <style name="text" foreground="\(hex(.text))" background="\(hex(.canvas))"/>
        <style name="selection" background="\(hex(.panel))" foreground="\(hex(.text))"/>
        <style name="cursor" foreground="\(hex(.accent))"/>
        <style name="current-line" background="\(hex(.panel))"/>
        <style name="line-numbers" foreground="\(hex(.muted))" background="\(hex(.canvas))"/>
        <style name="def:comment" foreground="\(hex(.muted))"/>
        <style name="def:keyword" foreground="\(hex(.keyword))" bold="true"/>
        <style name="def:type" foreground="\(hex(.accent))"/>
        <style name="def:string" foreground="\(hex(.string))"/>
        <style name="def:constant" foreground="\(hex(.number))"/>
        <style name="def:number" foreground="\(hex(.number))"/>
        <style name="def:function" foreground="\(hex(.accent))"/>
        <style name="diff:added-line" foreground="\(hex(.addition))"/>
        <style name="diff:removed-line" foreground="\(ThemeHex.string(app.ansiColors[1]))"/>
        <style name="diff:diff-file" foreground="\(hex(.accent))" bold="true"/>
        </style-scheme>
        """
        let schemeURL = configFolder.appendingPathComponent("styles/freemind.xml")
        do {
            if (try? String(contentsOf: schemeURL, encoding: .utf8)) != scheme {
                try FileManager.default.createDirectory(at: schemeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try scheme.write(to: schemeURL, atomically: true, encoding: .utf8)
            }
        } catch { await onUI { fm_error("Could not save editor colors: " + error.localizedDescription) } }
        await onUI { fm_appearance(css, colors, opacity); fm_source_colors(schemeURL.path) }

    }
}

private final class AppearanceReply {
    let reply: (Bool) -> Void
    init(_ reply: @escaping (Bool) -> Void) { self.reply = reply }
}
