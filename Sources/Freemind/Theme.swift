import AppKit
import SwiftUI
import FreemindCore

struct Theme: Equatable {
    var style: AppColorTheme = .forest
    var isDark = false
    var custom: CustomTheme?

    func hex(for role: ThemeColorRole) -> UInt32 {
        let variant = isDark ? custom?.dark : custom?.light
        if let value = variant?.colors[role.rawValue].flatMap(ThemeHex.parse) { return value }
        let pair: (UInt32, UInt32)
        switch role {
        case .background: pair = palette.background
        case .panel: pair = palette.panel
        case .canvas: pair = palette.canvas
        case .accent: pair = palette.accent
        case .text: pair = palette.text
        case .muted: pair = palette.muted
        case .keyword: pair = palette.keyword
        case .number: pair = palette.number
        case .string: pair = palette.string
        case .addition: pair = palette.addition
        }
        return isDark ? pair.1 : pair.0
    }
    private func color(_ role: ThemeColorRole) -> NSColor { Self.color(hex(for: role)) }
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    var nativeAccent: NSColor { color(.accent) }
    var nativeBackground: NSColor { color(.background) }
    var nativePanel: NSColor { color(.panel) }
    var nativeCanvas: NSColor { color(.canvas) }
    var nativeText: NSColor { color(.text) }
    var nativeMuted: NSColor { color(.muted) }
    var nativeSelection: NSColor { nativeCanvas.blended(withFraction: isDark ? 0.28 : 0.20, of: nativeAccent)! }
    var keyword: NSColor { color(.keyword) }
    var number: NSColor { color(.number) }
    var string: NSColor { color(.string) }
    var background: Color { Color(nsColor: nativeBackground) }
    var panel: Color { Color(nsColor: nativePanel) }
    var accent: Color { Color(nsColor: nativeAccent) }
    var border: Color { Color(nsColor: nativeText).opacity(0.12) }
    var addition: Color { Color(nsColor: color(.addition)) }
    var ansiColors: [UInt32] {
        if let colors = (isDark ? custom?.dark : custom?.light)?.ansiColors?.compactMap(ThemeHex.parse), colors.count == 16 { return colors }
        return isDark ? palette.ansiDark : palette.ansiLight
    }

    func customCopy(name: String) -> CustomTheme {
        var result = custom ?? CustomTheme(name: name, base: style)
        result.id = UUID().uuidString.lowercased(); result.name = name
        return result
    }

    // Light/dark pairs keep a theme's identity when appearance changes.
    // Palette references and adaptation notes are in Resources/licenses/Theme-inspirations.txt.
    private var palette: ThemePalette { Self.palettes[custom?.base ?? style]! }
    private static let palettes = Dictionary(uniqueKeysWithValues: AppColorTheme.allCases.map { ($0, makePalette($0)) })
    private static func makePalette(_ style: AppColorTheme) -> ThemePalette {
        switch style {
        case .forest:
            return .init(background: (0xEDF2EE, 0x161E1B), panel: (0xF6F9F6, 0x202C25),
                         canvas: (0xFBFDFB, 0x19221D), accent: (0x23764F, 0x82D6A7))
        case .ocean:
            return .init(background: (0xEDF2F8, 0x171E29), panel: (0xF6F9FD, 0x222D3D),
                         canvas: (0xFBFCFE, 0x1D2633), accent: (0x2467B2, 0x85BCF5))
        case .violet:
            return .init(background: (0xF3EFF7, 0x211C29), panel: (0xFAF7FD, 0x2D2537),
                         canvas: (0xFDFBFF, 0x251F2E), accent: (0x7850AE, 0xC3A2EE))
        case .graphite:
            return .init(background: (0xF0F1F3, 0x1C1E22), panel: (0xF8F9FA, 0x282C32),
                         canvas: (0xFDFDFE, 0x202328), accent: (0x58616D, 0xB9C3D0))
        case .vscode:
            return .init(background: (0xF3F3F3, 0x252526), panel: (0xF8F8F8, 0x2D2D30),
                         canvas: (0xFFFFFF, 0x1E1E1E), accent: (0x0066B8, 0x75BEFF),
                         text: (0x333333, 0xD4D4D4), muted: (0x008000, 0x6A9955),
                         keyword: (0x0000FF, 0x569CD6), number: (0x098658, 0xB5CEA8), string: (0xA31515, 0xCE9178),
                         addition: (0x16825D, 0x89D185),
                         ansiLight: [0x000000, 0xCD3131, 0x107C10, 0x795E00, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
                                     0x666666, 0xB52020, 0x147514, 0x886500, 0x0451A5, 0xA300A3, 0x007F9E, 0x767676],
                         ansiDark: [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                                    0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF])
        case .one:
            return .init(background: (0xEAEAEB, 0x21252B), panel: (0xF0F0F0, 0x2C313C),
                         canvas: (0xFAFAFA, 0x282C34), accent: (0x4078F2, 0x61AFEF),
                         text: (0x383A42, 0xABB2BF), muted: (0x696C77, 0x828997),
                         keyword: (0xA626A4, 0xC678DD), number: (0x986801, 0xD19A66), string: (0x50A14F, 0x98C379),
                         addition: (0x39853B, 0x98C379),
                         ansiLight: [0x383A42, 0xE45649, 0x50A14F, 0x986801, 0x4078F2, 0xA626A4, 0x0184BC, 0x696C77,
                                     0x5D606A, 0xCA3D32, 0x39853B, 0x805800, 0x2860D5, 0x902090, 0x006FA0, 0x767A85],
                         ansiDark: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                                    0x5C6370, 0xE9969D, 0xB4D59D, 0xEDD3A3, 0x8DC5F4, 0xD7A1E7, 0x85CBD3, 0xFFFFFF])
        case .dracula:
            return .init(background: (0xEFEBF5, 0x21222C), panel: (0xF7F3FB, 0x343746),
                         canvas: (0xFAF7FF, 0x282A36), accent: (0x7652B4, 0xBD93F9),
                         text: (0x3D354C, 0xF8F8F2), muted: (0x736580, 0x8895BE),
                         keyword: (0xB32A79, 0xFF79C6), number: (0x7652B4, 0xBD93F9), string: (0x807000, 0xF1FA8C),
                         addition: (0x287A46, 0x50FA7B),
                         ansiLight: [0x3D354C, 0xBD3545, 0x287A46, 0x807000, 0x5364B8, 0xA33183, 0x287C89, 0x736580,
                                     0x655870, 0xA8283A, 0x216638, 0x6D6000, 0x4353A0, 0x8F2471, 0x206B76, 0x81728F],
                         ansiDark: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                                    0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])
        case .github:
            return .init(background: (0xF6F8FA, 0x010409), panel: (0xF0F3F6, 0x161B22),
                         canvas: (0xFFFFFF, 0x0D1117), accent: (0x0969DA, 0x58A6FF),
                         text: (0x24292F, 0xC9D1D9), muted: (0x57606A, 0x8B949E),
                         keyword: (0xCF222E, 0xFF7B72), number: (0x0550AE, 0x79C0FF), string: (0x0A3069, 0xA5D6FF),
                         addition: (0x1A7F37, 0x3FB950),
                         ansiLight: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                                     0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x0550AE, 0x6639BA, 0x096C73, 0x767E89],
                         ansiDark: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
                                    0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC])
        case .nord:
            return .init(background: (0xE5E9F0, 0x292E39), panel: (0xE8EDF3, 0x3B4252),
                         canvas: (0xECEFF4, 0x2E3440), accent: (0x476B8E, 0x88C0D0),
                         text: (0x2E3440, 0xD8DEE9), muted: (0x626E84, 0x8F9BB0),
                         keyword: (0x476B8E, 0x81A1C1), number: (0x8C6387, 0xB48EAD), string: (0x526F3F, 0xA3BE8C),
                         addition: (0x526F3F, 0xA3BE8C),
                         ansiLight: [0x2E3440, 0xA5424D, 0x526F3F, 0x806020, 0x476B8E, 0x8C6387, 0x357380, 0x626E84,
                                     0x4C566A, 0x953944, 0x456233, 0x705218, 0x3D5F82, 0x7F547A, 0x2B6672, 0x727E92],
                         ansiDark: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                                    0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
        case .solarized:
            return .init(background: (0xEEE8D5, 0x00212B), panel: (0xF5EEDB, 0x073642),
                         canvas: (0xFDF6E3, 0x002B36), accent: (0x2176A8, 0x2AA198),
                         text: (0x586E75, 0x93A1A1), muted: (0x657B83, 0x839496),
                         keyword: (0x677B00, 0x859900), number: (0xB52C70, 0xD33682), string: (0x187F78, 0x2AA198),
                         addition: (0x677B00, 0x859900),
                         ansiLight: [0x073642, 0xC52C2A, 0x677B00, 0x8C6800, 0x2176A8, 0xB52C70, 0x187F78, 0x657B83,
                                     0x002B36, 0xB44113, 0x586E75, 0x657B83, 0x2176A8, 0x6C71C4, 0x187F78, 0x75878B],
                         ansiDark: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                    0x586E75, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0x6C71C4, 0x93A1A1, 0xFDF6E3])
        case .tokyoNight:
            return .init(background: (0xD5D6DB, 0x16161E), panel: (0xDCDEE4, 0x24283B),
                         canvas: (0xE1E2E7, 0x1A1B26), accent: (0x34548A, 0x7AA2F7),
                         text: (0x343B58, 0xA9B1D6), muted: (0x626C91, 0x858DB1),
                         keyword: (0x784DBA, 0xBB9AF7), number: (0x965027, 0xFF9E64), string: (0x485E30, 0x9ECE6A),
                         addition: (0x485E30, 0x9ECE6A),
                         ansiLight: [0x343B58, 0x8C4351, 0x485E30, 0x8F5E15, 0x34548A, 0x784DBA, 0x0F4B6E, 0x626C91,
                                     0x4C557B, 0xA83A51, 0x3B5424, 0x7A4E0C, 0x2B4880, 0x663FA5, 0x0C405F, 0x6D779D],
                         ansiDark: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                                    0x565F89, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])
        case .catppuccin:
            return .init(background: (0xE6E9EF, 0x181825), panel: (0xDCE0E8, 0x313244),
                         canvas: (0xEFF1F5, 0x1E1E2E), accent: (0x8839EF, 0xCBA6F7),
                         text: (0x4C4F69, 0xCDD6F4), muted: (0x6C6F85, 0x9399B2),
                         keyword: (0x8839EF, 0xCBA6F7), number: (0xB84C08, 0xFAB387), string: (0x357D23, 0xA6E3A1),
                         addition: (0x357D23, 0xA6E3A1),
                         ansiLight: [0x4C4F69, 0xD20F39, 0x357D23, 0x956016, 0x1E66F5, 0x8839EF, 0x137980, 0x6C6F85,
                                     0x5C5F77, 0xB80D31, 0x2E6D1E, 0x80510E, 0x1957D4, 0x762DD5, 0x106970, 0x7C7F93],
                         ansiDark: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                                    0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8])
        }
    }
}

private struct ThemePalette {
    var background: (UInt32, UInt32)
    var panel: (UInt32, UInt32)
    var canvas: (UInt32, UInt32)
    var accent: (UInt32, UInt32)
    var text = (UInt32(0x252C35), UInt32(0xE0E7EF))
    var muted = (UInt32(0x626E7A), UInt32(0xA1ADBA))
    var keyword = (UInt32(0x7944A8), UInt32(0xCBA0F4))
    var number = (UInt32(0x965009), UInt32(0xEFB16E))
    var string = (UInt32(0x34713A), UInt32(0x95CF96))
    var addition = (UInt32(0x287544), UInt32(0x8ACB9D))
    var ansiLight: [UInt32] = [0x29313C, 0xAD343A, 0x2D713D, 0x855B08, 0x2B63AD, 0x8449A3, 0x216F77, 0x687381,
                             0x596575, 0xB63740, 0x347543, 0x88600B, 0x356AB7, 0x8C4CB0, 0x277A82, 0x737D89]
    var ansiDark: [UInt32] = [0x46515E, 0xF08080, 0x8BCD99, 0xE4C078, 0x8DBAF0, 0xC7A0E8, 0x7BCAC9, 0xD8DEE8,
                            0x8995A4, 0xFFA1A1, 0xADE6B6, 0xF4D89E, 0xB3D5FF, 0xDEC0FA, 0xA5E7E6, 0xFFFFFF]
}

private struct AppThemeKey: EnvironmentKey { static let defaultValue = Theme() }
private struct TerminalThemeKey: EnvironmentKey { static let defaultValue = Theme() }
extension EnvironmentValues {
    var appTheme: Theme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
    var terminalTheme: Theme {
        get { self[TerminalThemeKey.self] }
        set { self[TerminalThemeKey.self] = newValue }
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let settings = store.settings
        let dark = settings.appearance == .dark || (settings.appearance == .system && colorScheme == .dark)
        let custom = store.customThemes.first { $0.id == settings.customThemeID }
        let theme = Theme(style: settings.theme, isDark: dark, custom: custom)
        let terminalCustom = settings.terminalCustomThemeID != nil
            ? store.customThemes.first { $0.id == settings.terminalCustomThemeID }
            : (settings.terminalTheme == nil ? custom : nil)
        let terminalDark = settings.terminalAppearance == .dark || (settings.terminalAppearance == .app && dark)
        content
            .environment(\.appTheme, theme)
            .environment(\.terminalTheme, Theme(style: settings.terminalTheme ?? settings.theme, isDark: terminalDark, custom: terminalCustom))
            .tint(theme.accent)
            .preferredColorScheme(settings.appearance == .system ? nil : settings.appearance == .dark ? .dark : .light)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let error = store.themeError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        ScrollView { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70)
                        Button("Reload") { store.reloadThemes() }
                    }.foregroundStyle(.orange).padding(10).background(theme.panel)
                }
            }
    }
}

extension View {
    func appAppearance(store: AppStore) -> some View { modifier(AppAppearanceModifier(store: store)) }
}
