import XCTest
@testable import FreemindCore

final class CustomThemeTests: XCTestCase {
    private func configURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-themes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("themes.json")
    }
    private func sample() -> CustomTheme {
        var theme = CustomTheme(id: "amber", name: "Amber", base: .graphite)
        theme.light.colors = ["accent": "#885500", "canvas": "#FFF8EF"]
        theme.dark.colors = ["accent": "#FFCC88", "canvas": "#221100"]
        theme.dark.ansiColors = (0..<16).map { ThemeHex.string(UInt32($0) * 0x101010) }
        return theme
    }

    func testConfigurationRoundTripsBothVariantsAndReadableHex() throws {
        let url = try configURL()
        XCTAssertNil(try CustomThemeConfiguration.read(from: url).data)
        let configuration = CustomThemeConfiguration(themes: [sample()])
        try configuration.save(to: url, expected: nil)
        XCTAssertEqual(try CustomThemeConfiguration.read(from: url).configuration, configuration)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("#FFCC88")); XCTAssertTrue(text.contains("ansiColors"))
    }
    func testInvalidColorsAndANSICountDoNotReplaceFile() throws {
        let url = try configURL()
        let configuration = CustomThemeConfiguration(themes: [sample()])
        try configuration.save(to: url, expected: nil)
        let original = try Data(contentsOf: url)
        for color in ["red", "FFCC88", "#FFF", "#12345678", "#ZZZZZZ", "#FFCC88\n"] {
            var invalid = configuration; invalid.themes[0].dark.colors["accent"] = color
            XCTAssertThrowsError(try invalid.save(to: url, expected: original)) { XCTAssertTrue($0.localizedDescription.contains("dark.colors.accent")) }
        }
        var invalid = configuration; invalid.themes[0].dark.ansiColors = ["#000000"]
        XCTAssertThrowsError(try invalid.save(to: url, expected: original)) { XCTAssertTrue($0.localizedDescription.contains("exactly 16")) }
        invalid = configuration; invalid.themes[0].dark.ansiColors?[4] = "bad"
        XCTAssertThrowsError(try invalid.save(to: url, expected: original)) { XCTAssertTrue($0.localizedDescription.contains("ansiColors[4]")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testValidationRejectsDuplicateIDsNamesAndUnknownRoles() throws {
        let theme = sample()
        var other = theme; other.name = "Other"
        XCTAssertThrowsError(try CustomThemeConfiguration(themes: [theme, other]).validate())
        other.id = "other"; other.name = " amber "
        XCTAssertThrowsError(try CustomThemeConfiguration(themes: [theme, other]).validate())
        other.name = "Other"; other.dark.colors["acccent"] = "#FFFFFF"
        XCTAssertThrowsError(try other.validate()) { XCTAssertTrue($0.localizedDescription.contains("acccent")) }
        for id in ["../theme", "", "-theme", "theme\n"] {
            var invalid = theme; invalid.id = id; XCTAssertThrowsError(try invalid.validate())
        }
        var future = CustomThemeConfiguration(themes: [theme]); future.schemaVersion = 2
        XCTAssertThrowsError(try future.validate())
    }
    func testConcurrentSavePreservesExternalChanges() throws {
        let url = try configURL()
        let configuration = CustomThemeConfiguration(themes: [sample()])
        try configuration.save(to: url, expected: nil)
        let original = try Data(contentsOf: url)
        var external = configuration; external.themes[0].name = "External name"
        try external.save(to: url, expected: original)
        XCTAssertThrowsError(try configuration.save(to: url, expected: original)) { XCTAssertTrue($0.localizedDescription.contains("changed on disk")) }
        XCTAssertEqual(try CustomThemeConfiguration.read(from: url).configuration, external)
    }
    func testMalformedEditsReportErrorsInsteadOfSilentlyLoadingBackup() throws {
        let url = try configURL()
        var configuration = CustomThemeConfiguration(themes: [sample()])
        try configuration.save(to: url, expected: nil)
        let data = try Data(contentsOf: url)
        configuration.themes[0].name = "Second save"; try configuration.save(to: url, expected: data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path))
        try Data("{ unfinished".utf8).write(to: url)
        XCTAssertThrowsError(try CustomThemeConfiguration.read(from: url)) { XCTAssertTrue($0.localizedDescription.contains("Invalid themes.json")) }
        let missingField = #"{"schemaVersion":1,"themes":[{"id":"a","name":"A","base":"forest","light":{"colors":{}}}]}"#
        try Data(missingField.utf8).write(to: url)
        XCTAssertThrowsError(try CustomThemeConfiguration.read(from: url)) { XCTAssertTrue($0.localizedDescription.contains("dark")) }
    }
    func testDocumentedExampleIsValidAndCodexTargetsSelectedTheme() throws {
        let example = try XCTUnwrap(CustomThemeConfiguration.instructions.components(separatedBy: "```json\n").dropFirst().first?.components(separatedBy: "\n```").first)
        let configuration = try JSONDecoder().decode(CustomThemeConfiguration.self, from: Data(example.utf8))
        try configuration.validate()
        let theme = sample(), request = "Warm amber with quiet blue highlights"
        let prompt = CustomThemeConfiguration.codexPrompt(theme: theme, request: request)
        XCTAssertTrue(prompt.contains(theme.id)); XCTAssertTrue(prompt.contains(request))
        XCTAssertTrue(prompt.contains("THEMES.md")); XCTAssertTrue(prompt.contains("themes.json"))
    }
}
