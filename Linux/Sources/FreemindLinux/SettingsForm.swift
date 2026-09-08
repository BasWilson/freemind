import Foundation
import FreemindCore
import LinuxUI

extension Controller {
    func showSettings(page: String = "") async throws {
        let settings = settings, themes = themes, options = defaultsDraft, scope = defaultsScope
        let kind = paneKind, title = paneTitle, useDefaults = paneSaveDefaults
        let hasWorkspace = paths != nil, draft = themeDraft, variant = themeVariant, json = themeJSON, request = themeRequest
        let update = await updater.snapshot()
        await onUI {
            func choice(_ key: String, _ title: String, _ values: [(String, String)], _ selected: String) {
                var values = values
                if !values.contains(where: { $0.0 == selected }) { values.append((selected, selected.isEmpty ? "Default" : selected)) }
                fm_settings_choice(key, title, values.map(\.0).joined(separator: "\n"), values.map(\.1).joined(separator: "\n"), selected)
            }
            func toggle(_ key: String, _ title: String, _ value: Bool) { fm_settings_toggle(key, title, value ? 1 : 0) }
            func text(_ key: String, _ title: String, _ value: String, _ hint: String = "", lines: Int32 = 0) { fm_settings_text(key, title, value, hint, lines) }
            let builtins = AppColorTheme.allCases.map { ("builtin:" + $0.rawValue, $0.title) }
            let choices = builtins + themes.themes.map { ("custom:" + $0.id, $0.name + " (Custom)") }
            fm_settings_begin()
            fm_settings_page("appearance", "Appearance")
            fm_settings_section("App appearance", "System follows your desktop’s light or dark preference. Changes apply immediately.")
            choice("appearance", "Mode", AppAppearance.allCases.map { ($0.rawValue, $0.title) }, settings.appearance.rawValue)
            choice("theme", "Color theme", choices, settings.customThemeID.map { "custom:" + $0 } ?? "builtin:" + settings.theme.rawValue)
            fm_settings_section("Terminal appearance", "Choose a separate look for running and new terminals.")
            choice("terminalAppearance", "Mode", TerminalAppearance.allCases.map { ($0.rawValue, $0.title) }, settings.terminalAppearance.rawValue)
            choice("terminalTheme", "Color theme", [("app", "Match app")] + choices, settings.terminalCustomThemeID.map { "custom:" + $0 } ?? settings.terminalTheme.map { "builtin:" + $0.rawValue } ?? "app")
            fm_settings_section("Window transparency", "Applies to the main window. Background blur follows your compositor’s configuration.")
            toggle("translucentWindows", "Translucent main window", settings.translucentWindows)
            fm_settings_range("windowOpacity", "Window opacity (%)", settings.windowOpacity * 100, 65, 100)

            fm_settings_page("defaults", "Terminal defaults")
            fm_settings_section("Terminal defaults", "Global defaults seed new workspaces. Workspace defaults apply to new terminals in that folder. Existing terminals keep their launch options.")
            if scope == "new" {
                choice("pane.kind", "Terminal type", [("codex", "Codex"), ("shell", "Shell")], kind.rawValue)
                text("pane.title", "Terminal title", title, "Automatic")
                toggle("pane.defaults", "Save as workspace defaults", useDefaults)
            } else {
            choice("defaultsScope", "Save defaults for", [("global", "New workspaces")] + (hasWorkspace ? [("workspace", "Current workspace")] : []), scope)
            }
            fm_settings_button("CLI Help", "cli-help", 1)
            fm_settings_section("Model & profile", "Model names and reasoning levels are passed to your installed CLI.")
            text("options.model", "Model", options.model, "Use Codex default")
            text("options.profile", "Profile", options.profile, "Use Codex default")
            choice("options.reasoning", "Reasoning effort", [("", "Use Codex default")] + ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].map { ($0, $0) }, options.reasoning)
            fm_settings_section("Permissions", "Workspace trust loads the project’s Codex configuration, hooks and rules without the directory trust prompt.")
            toggle("options.trustWorkspace", "Trust workspace when opening Codex", options.automaticallyTrustWorkspace)
            choice("options.sandbox", "Sandbox", [("", "Use Codex default"), ("read-only", "Read only"), ("workspace-write", "Workspace write"), ("danger-full-access", "Full access")], options.sandbox)
            choice("options.approval", "Approval policy", [("", "Use Codex default"), ("on-request", "On request"), ("auto", "Automatic review"), ("never", "Never ask")], options.approval)
            text("options.additionalDirectories", "Additional directories (one per line)", options.additionalDirectories.joined(separator: "\n"), lines: 1)
            fm_settings_section("Features", "Activity hooks record session IDs and status. They do not modify prompts or approve actions.")
            toggle("options.webSearch", "Enable web search", options.webSearch)
            toggle("options.inline", "Keep terminal scrollback (inline display)", options.inline)
            toggle("options.hooks", "Show Codex activity in Freemind", options.hooks)
            choice("options.localProvider", "Local provider", [("", "Use configured provider"), ("ollama", "Ollama"), ("lmstudio", "LM Studio")], options.localProvider)
            fm_settings_section("Advanced", "Additional arguments support quoted values. Shell substitutions are passed literally.")
            text("options.executable", "Codex executable", options.executable, "Find codex in your login shell’s PATH")
            text("options.configOverrides", "Config overrides (key=value, one per line)", options.configOverrides.joined(separator: "\n"), lines: 1)
            text("options.extraArguments", "Additional CLI arguments", options.extraArguments, "--enable feature_name", lines: 1)
            fm_settings_button(scope == "new" ? "Create Terminal" : "Save Defaults", scope == "new" ? "pane-create" : "defaults-save", 1)
            if scope == "workspace" { fm_settings_button("Use Global Defaults", "defaults-global", 1) }
            fm_settings_button("Reset to Built-in Defaults", "defaults-reset", 1)

            fm_settings_page("themes", "Custom themes")
            fm_settings_section("Your own palette", "Create and edit light and dark palettes. Leave colors empty to inherit the base theme.")
            fm_settings_button("New Theme", "theme-new", 1)
            choice("editTheme", "Edit theme", [("", "Choose a theme")] + themes.themes.map { ($0.id, $0.name) }, draft?.id ?? "")
            if let draft {
                text("theme.name", "Theme name", draft.name)
                choice("theme.base", "Base palette", AppColorTheme.allCases.map { ($0.rawValue, $0.title) }, draft.base.rawValue)
                choice("themeVariant", "Editing", [("dark", "Dark"), ("light", "Light")], variant)
                let colors = variant == "dark" ? draft.dark : draft.light
                let base = ThemeColors(style: draft.base, isDark: variant == "dark")
                for role in ThemeColorRole.allCases {
                    text("theme." + role.rawValue, role.title, colors.colors[role.rawValue] ?? "", ThemeHex.string(base.hex(for: role)))
                }
                text("theme.ansi", "Terminal ANSI colors (16 hex colors, optional)", colors.ansiColors?.joined(separator: " ") ?? "", lines: 1)
                fm_settings_button("Reset This Variant to Base", "theme-reset", 1)
                fm_settings_button("Save & Use Theme", "theme-save", 1)
                fm_settings_section("Create with Codex", "Start a terminal in your Themes folder. Codex receives this description and the theme guide; valid saved edits apply automatically.")
                text("themeRequest", "Describe the look you want", request, lines: 1)
                fm_settings_button("Save Theme & Start Codex", "theme-design", 1)
            }
            fm_settings_section("Theme configuration", "The same themes.json format works on macOS and Linux. Invalid edits keep the last valid colors.")
            fm_settings_button("Open Theme Configuration", "themes-open", 1)
            fm_settings_button("Reload Themes", "themes-reload", 1)
            text("themesJSON", "themes.json", json, lines: 2)
            fm_settings_button("Validate & Save Configuration", "themes-save", 1)

            fm_settings_page("general", "General")
            fm_settings_section("Freemind", "A local workspace for Codex, your code, and Git. Quitting keeps terminals running; closing a terminal stops its process.")
            fm_settings_section("Software updates", "Version \(update.version). \(update.explanation)")
            toggle("updates.checks", "Automatically check for updates", update.checks)
            toggle("updates.downloads", "Download and install updates when quitting", update.downloads)
            fm_settings_button("Check for Updates", "update-check", update.canCheck ? 1 : 0)
            fm_settings_button("Download Update", "update-download", update.canDownload ? 1 : 0)
            fm_update_status(update.message, update.canCheck ? 1 : 0, update.canDownload ? 1 : 0)
            fm_settings_end(page)
        }
    }
}
