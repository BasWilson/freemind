import XCTest
import FreemindCore
@testable import Freemind

final class ThemeTests: XCTestCase {
    func testCustomColorsInheritBaseAndRespectAppearance() {
        var custom = CustomTheme(name: "Amber", base: .graphite)
        custom.dark.colors["accent"] = "#FFCC88"
        custom.light.colors["accent"] = "#885500"
        let dark = Theme(style: .forest, isDark: true, custom: custom)
        let light = Theme(style: .forest, isDark: false, custom: custom)
        XCTAssertEqual(dark.hex(for: .accent), 0xFFCC88)
        XCTAssertEqual(light.hex(for: .accent), 0x885500)
        XCTAssertEqual(dark.hex(for: .canvas), Theme(style: .graphite, isDark: true).hex(for: .canvas))
        XCTAssertEqual(light.ansiColors, Theme(style: .graphite).ansiColors)
    }
    func testANSIPaletteAndLiveThemeEqualityIncludeCustomEdits() {
        var custom = CustomTheme(name: "Amber")
        let before = Theme(isDark: true, custom: custom)
        custom.dark.ansiColors = (0..<16).map { ThemeHex.string(UInt32($0) * 0x101010) }
        let after = Theme(isDark: true, custom: custom)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.ansiColors[3], 0x303030)
        XCTAssertEqual(after.ansiColors.count, 16)
        custom.dark.ansiColors = ["invalid"]
        XCTAssertEqual(Theme(isDark: true, custom: custom).ansiColors, before.ansiColors)
    }
    func testDuplicatingThemePreservesColorsWithANewIdentity() {
        var custom = CustomTheme(name: "Original", base: .ocean)
        custom.dark.colors["accent"] = "#112233"
        let copy = Theme(custom: custom).customCopy(name: "Copy")
        XCTAssertNotEqual(copy.id, custom.id)
        XCTAssertEqual(copy.name, "Copy"); XCTAssertEqual(copy.base, custom.base)
        XCTAssertEqual(copy.dark, custom.dark); XCTAssertEqual(copy.light, custom.light)
    }
}
