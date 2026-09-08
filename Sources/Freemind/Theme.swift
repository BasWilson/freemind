import AppKit
import SwiftUI
import FreemindCore

struct Theme: Equatable {
    var style: AppColorTheme = .forest
    var isDark = false
    var custom: CustomTheme?

    private var colors: ThemeColors { ThemeColors(style: style, isDark: isDark, custom: custom) }
    func hex(for role: ThemeColorRole) -> UInt32 { colors.hex(for: role) }
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
    var ansiColors: [UInt32] { colors.ansiColors }
    func customCopy(name: String) -> CustomTheme { colors.customCopy(name: name) }
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
    var mainWindow: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let settings = store.settings
        let dark = settings.appearance == .dark || (settings.appearance == .system && colorScheme == .dark)
        let custom = store.customThemes.first { $0.id == settings.customThemeID }
        let theme = Theme(style: settings.theme, isDark: dark, custom: custom)
        let terminalCustom = settings.terminalCustomThemeID != nil
            ? store.customThemes.first { $0.id == settings.terminalCustomThemeID }
            : (settings.terminalTheme == nil ? custom : nil)
        let terminalDark = settings.terminalAppearance == .dark || (settings.terminalAppearance == .app && dark)
        let opacity = mainWindow ? settings.effectiveWindowOpacity(reduceTransparency: reduceTransparency) : 1
        content
            .opacity(opacity)
            .background {
                if mainWindow { WindowBackdrop(enabled: opacity < 1).ignoresSafeArea() }
            }
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
    func appAppearance(store: AppStore, mainWindow: Bool = false) -> some View { modifier(AppAppearanceModifier(store: store, mainWindow: mainWindow)) }
}
