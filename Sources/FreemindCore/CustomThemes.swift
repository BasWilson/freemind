import Foundation

public enum ThemeColorRole: String, CaseIterable, Sendable {
    case background, panel, canvas, accent, text, muted, keyword, number, string, addition
    public var title: String {
        switch self {
        case .canvas: return "Editor & terminal background"
        case .muted: return "Comments & muted text"
        case .addition: return "Git additions"
        default: return rawValue.capitalized
        }
    }
}

public enum ThemeHex {
    public static func parse(_ value: String) -> UInt32? {
        guard value.utf8.count == 7, value.first == "#",
              value.dropFirst().allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }
    public static func string(_ value: UInt32) -> String { String(format: "#%06X", value & 0xFFFFFF) }
}

public struct CustomThemeVariant: Codable, Equatable, Sendable {
    public var colors: [String: String] = [:]
    public var ansiColors: [String]?
    public init() {}

    public func validate(at path: String) throws {
        for (role, value) in colors.sorted(by: { $0.key < $1.key }) {
            guard ThemeColorRole(rawValue: role) != nil else { throw FreemindError.message("\(path).colors.\(role): unknown color. Use \(ThemeColorRole.allCases.map(\.rawValue).joined(separator: ", ")).") }
            guard ThemeHex.parse(value) != nil else { throw FreemindError.message("\(path).colors.\(role): use a six-digit hex color such as #82D6A7.") }
        }
        if let ansiColors {
            guard ansiColors.count == 16 else { throw FreemindError.message("\(path).ansiColors must contain exactly 16 hex colors.") }
            for (index, value) in ansiColors.enumerated() where ThemeHex.parse(value) == nil {
                throw FreemindError.message("\(path).ansiColors[\(index)]: use a six-digit hex color such as #82D6A7.")
            }
        }
    }
}

public struct CustomTheme: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var base: AppColorTheme
    public var light: CustomThemeVariant
    public var dark: CustomThemeVariant
    public init(id: String = UUID().uuidString.lowercased(), name: String, base: AppColorTheme = .forest,
                light: CustomThemeVariant = .init(), dark: CustomThemeVariant = .init()) {
        self.id = id; self.name = name; self.base = base; self.light = light; self.dark = dark
    }
    public func validate() throws {
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", options: .regularExpression) == id.startIndex..<id.endIndex else {
            throw FreemindError.message("Theme IDs must use 1–80 letters, digits, hyphens, or underscores, starting with a letter or digit.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw FreemindError.message("Give each theme a name of 1–80 characters on one line.")
        }
        try light.validate(at: "\(name).light"); try dark.validate(at: "\(name).dark")
    }
}

public struct CustomThemeConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var themes: [CustomTheme] = []
    public init(themes: [CustomTheme] = []) { self.themes = themes }

    public func validate() throws {
        guard schemaVersion == 1 else { throw FreemindError.message("Unsupported theme schemaVersion \(schemaVersion). Use schemaVersion 1.") }
        var ids = Set<String>(), names = Set<String>()
        for theme in themes {
            try theme.validate()
            guard ids.insert(theme.id).inserted else { throw FreemindError.message("Duplicate theme ID ‘\(theme.id)’. Give each theme a unique ID.") }
            guard names.insert(theme.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted else {
                throw FreemindError.message("Duplicate theme name ‘\(theme.name)’. Give each theme a different name.")
            }
        }
    }

    public static func read(from url: URL) throws -> (configuration: CustomThemeConfiguration, data: Data?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.init(), nil) }
        let data = try Data(contentsOf: url)
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate()
            return (value, data)
        } catch let error as DecodingError {
            let context: DecodingError.Context
            var field: String?
            switch error {
            case .keyNotFound(let key, let value): context = value; field = key.stringValue
            case .dataCorrupted(let value), .typeMismatch(_, let value), .valueNotFound(_, let value): context = value
            @unknown default: throw error
            }
            let path = (context.codingPath.map(\.stringValue) + (field.map { [$0] } ?? [])).joined(separator: ".")
            throw FreemindError.message("Invalid themes.json\(path.isEmpty ? "" : " at " + path): \(context.debugDescription)")
        }
    }

    public func save(to url: URL, expected: Data?) throws {
        try validate()
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == expected else { throw FreemindError.message("themes.json changed on disk. Reload themes and try again so your other edits are preserved.") }
        try DurableFile.save(self, to: url)
    }

    public static let instructions = """
    # Freemind custom themes

    Edit `themes.json` in this folder. Freemind reloads valid saves automatically,
    including running terminals. Invalid edits show an error in Appearance settings
    and keep the last valid colors. Choose a theme in Settings → Appearance to use it.
    App and terminal themes can be selected independently, with light/dark modes.

    ## Format

    ```json
    {
      "schemaVersion": 1,
      "themes": [
        {
          "id": "my-theme",
          "name": "My Theme",
          "base": "forest",
          "light": { "colors": { "accent": "#23764F" } },
          "dark": { "colors": { "accent": "#82D6A7" } }
        }
      ]
    }
    ```

    - Keep schemaVersion at 1. Use strict JSON: no comments or trailing commas.
    - Keep existing themes and IDs when editing. For a new theme, add an entry with
      a unique ID (1–80 letters/digits/hyphens/underscores, starting with a letter
      or digit) and a unique, nonempty name of at most 80 characters.
    - Required theme fields: id, name, base, light, dark. Each variant requires colors.
    - Built-in base values: forest, ocean, violet, graphite, vscode, one, dracula,
      github, nord, solarized, tokyoNight, catppuccin.
    - Both variants inherit unspecified colors from their built-in base.
    - Colors use exactly #RRGGBB. Supported keys in colors:
      background (workspace), panel (sidebars/toolbars), canvas (editor/terminal),
      accent (controls/cursor), text (editor/terminal text), muted (comments),
      keyword, number, string (syntax highlighting), addition (Git additions).
    - Each variant may also include ansiColors beside colors. Supply exactly 16
      #RRGGBB values in this order: black, red, green, yellow, blue, magenta, cyan,
      white, bright black, bright red, bright green, bright yellow, bright blue,
      bright magenta, bright cyan, bright white. Omit it to inherit the base palette.
    - Keep text, comments, syntax, and ANSI colors readable on the canvas in both
      modes. Keep red/green/yellow status colors distinguishable. Selection and
      borders are derived from the palette. Programs may set their own terminal colors.

    ## Instructions for Codex

    Read themes.json before editing. Follow the user's description and update the
    requested theme, preserving its ID and all unrelated entries. Customize both
    light and dark variants unless the user asks otherwise. Modify only the theme
    configuration for this task; there is no need to edit Freemind's source code or
    settings.json, or to build/restart the app. Validate the JSON, IDs, hex values,
    and 16-color ANSI arrays before saving. Explain the palette choices briefly.
    If a selected theme is being edited, its valid saved colors appear immediately.
    """

    public static func codexPrompt(theme: CustomTheme, request: String) -> String {
        """
        Create a Freemind theme matching the description below.
        Read THEMES.md for the configuration format and edit themes.json in this workspace.
        A starter theme named \(theme.name) with ID \(theme.id) is already selected in the app.
        Update that entry in place, preserving its ID and all other themes. Supply both
        light and dark variants and a readable terminal palette. Validate the file before
        saving; valid changes apply automatically. No app source changes or restart are needed.

        User's description:
        \(request)
        """
    }
}
