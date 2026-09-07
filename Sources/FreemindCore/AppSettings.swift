import Foundation

public enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var title: String { rawValue.capitalized }
}

public enum AppColorTheme: String, Codable, CaseIterable, Sendable {
    case forest, ocean, violet, graphite
    case vscode, one, dracula, github, nord, solarized, tokyoNight, catppuccin
    public var title: String {
        switch self {
        case .vscode: return "VS Code"
        case .one: return "One Dark / Light"
        case .github: return "GitHub"
        case .tokyoNight: return "Tokyo Night"
        default: return rawValue.capitalized
        }
    }
}

public enum TerminalAppearance: String, Codable, CaseIterable, Sendable {
    case app, light, dark
    public var title: String { self == .app ? "Match app" : rawValue.capitalized }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var workspaceDefaults = CodexOptions()
    public var appearance = AppAppearance.system
    public var theme = AppColorTheme.forest
    public var terminalTheme: AppColorTheme?
    public var customThemeID: String?
    public var terminalCustomThemeID: String?
    public var terminalAppearance = TerminalAppearance.app
    public init() {}

    private enum CodingKeys: String, CodingKey { case workspaceDefaults, appearance, theme, terminalTheme, terminalAppearance, customThemeID, terminalCustomThemeID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceDefaults = try values.decodeIfPresent(CodexOptions.self, forKey: .workspaceDefaults) ?? CodexOptions()
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        theme = try values.decodeIfPresent(String.self, forKey: .theme).flatMap(AppColorTheme.init(rawValue:)) ?? .forest
        terminalTheme = try values.decodeIfPresent(String.self, forKey: .terminalTheme).flatMap(AppColorTheme.init(rawValue:))
        customThemeID = try values.decodeIfPresent(String.self, forKey: .customThemeID)
        terminalCustomThemeID = try values.decodeIfPresent(String.self, forKey: .terminalCustomThemeID)
        terminalAppearance = try values.decodeIfPresent(String.self, forKey: .terminalAppearance).flatMap(TerminalAppearance.init(rawValue:)) ?? .app
    }

    public static func load(from url: URL) throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) else { return AppSettings() }
        return try DurableFile.load(AppSettings.self, from: url)
    }

    public func save(to url: URL) throws {
        _ = try workspaceDefaults.arguments()
        try DurableFile.save(self, to: url)
    }
}
