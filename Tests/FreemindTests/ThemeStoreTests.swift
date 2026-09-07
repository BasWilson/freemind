import XCTest
import FreemindCore
@testable import Freemind

final class ThemeStoreTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-theme-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor func testReloadKeepsLastValidColorsAndRecoversAfterRepair() throws {
        let folder = try folder(), url = folder.appendingPathComponent("themes.json")
        let theme = CustomTheme(id: "amber", name: "Amber")
        try CustomThemeConfiguration(themes: [theme]).save(to: url, expected: nil)
        let store = AppStore(settingsURL: folder.appendingPathComponent("settings.json"), themesURL: url)
        XCTAssertEqual(store.customThemes, [theme])
        let broken = Data("{ incomplete".utf8); try broken.write(to: url)
        store.reloadThemes()
        XCTAssertEqual(store.customThemes, [theme]); XCTAssertNotNil(store.themeError)
        var repaired = theme; repaired.dark.colors["accent"] = "#FFCC88"
        try CustomThemeConfiguration(themes: [repaired]).save(to: url, expected: broken)
        store.reloadThemes()
        XCTAssertEqual(store.customThemes, [repaired]); XCTAssertNil(store.themeError)
        try FileManager.default.removeItem(at: url)
        store.reloadThemes()
        XCTAssertEqual(store.customThemes, [repaired]); XCTAssertTrue(store.themeError?.contains("removed") == true)
    }

    @MainActor func testEditorPreservesOtherExternalThemesAndRejectsStaleEdits() throws {
        let folder = try folder(), url = folder.appendingPathComponent("themes.json")
        let original = CustomTheme(id: "amber", name: "Amber")
        try CustomThemeConfiguration(themes: [original]).save(to: url, expected: nil)
        let store = AppStore(settingsURL: folder.appendingPathComponent("settings.json"), themesURL: url)
        let other = CustomTheme(id: "ocean", name: "Ocean", base: .ocean)
        try CustomThemeConfiguration(themes: [original, other]).save(to: url, expected: Data(contentsOf: url))
        var edited = original; edited.name = "Edited Amber"
        try store.saveCustomTheme(edited, replacing: original)
        XCTAssertEqual(store.customThemes, [edited, other])
        var external = edited; external.dark.colors["accent"] = "#FFCC88"
        try CustomThemeConfiguration(themes: [external, other]).save(to: url, expected: Data(contentsOf: url))
        XCTAssertThrowsError(try store.saveCustomTheme(edited, replacing: edited)) { XCTAssertTrue($0.localizedDescription.contains("outside the editor")) }
        XCTAssertEqual(try CustomThemeConfiguration.read(from: url).configuration.themes, [external, other])
    }

    @MainActor func testMissingSelectedCustomThemeShowsFallbackAndRecovers() throws {
        let folder = try folder(), url = folder.appendingPathComponent("themes.json"), settingsURL = folder.appendingPathComponent("settings.json")
        var settings = AppSettings(); settings.customThemeID = "amber"; settings.theme = .graphite
        try settings.save(to: settingsURL)
        let store = AppStore(settingsURL: settingsURL, themesURL: url)
        XCTAssertTrue(store.themeError?.contains("Using Graphite") == true)
        let theme = CustomTheme(id: "amber", name: "Amber", base: .graphite)
        try store.saveCustomTheme(theme, replacing: nil)
        XCTAssertNil(store.themeError)
        XCTAssertEqual(store.settings.customThemeID, "amber")
    }
}
