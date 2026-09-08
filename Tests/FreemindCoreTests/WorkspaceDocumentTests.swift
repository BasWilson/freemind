import XCTest
@testable import FreemindCore

final class WorkspaceDocumentTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    func testDraftRecoveryAndConflictDoNotOverwriteExternalEdits() throws {
        let root = try folder(), file = root.appendingPathComponent("hello.swift"), draft = root.appendingPathComponent("draft.json")
        try Data("hello 🙂\n".utf8).write(to: file)
        var first = WorkspaceDocument(draftURL: draft)
        try first.load(file); try first.change("edited 🙂\n", cursor: 4)
        try Data("external\n".utf8).write(to: file)
        var reopened = WorkspaceDocument(draftURL: draft)
        try reopened.load(file)
        XCTAssertEqual(reopened.text, "edited 🙂\n"); XCTAssertEqual(reopened.cursor, 4)
        XCTAssertThrowsError(try reopened.save())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external\n")
        let copy = root.appendingPathComponent("copy.swift")
        try reopened.saveCopy(to: copy); XCTAssertThrowsError(try reopened.saveCopy(to: copy))
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "edited 🙂\n")
        try reopened.load(file, force: true)
        XCTAssertEqual(reopened.text, "external\n"); XCTAssertFalse(reopened.dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.path))
    }
    func testCleanExternalEditsReloadAndFailedSwitchKeepsDraft() throws {
        let root = try folder(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        var document = WorkspaceDocument(draftURL: root.appendingPathComponent("draft.json"))
        try document.load(a); try Data("external".utf8).write(to: a)
        XCTAssertTrue(try document.externalChange()); XCTAssertEqual(document.text, "external")
        try document.change("my edits"); try Data("another external edit".utf8).write(to: a)
        XCTAssertThrowsError(try document.load(b)); XCTAssertEqual(document.url, a); XCTAssertEqual(document.text, "my edits")
    }
    func testBinaryLargeAndNonRegularFilesAreRejected() throws {
        let root = try folder(); var document = WorkspaceDocument()
        XCTAssertThrowsError(try document.load(root))
        let binary = root.appendingPathComponent("binary"); try Data([0, 1, 2, 255]).write(to: binary)
        XCTAssertThrowsError(try document.load(binary))
        let large = root.appendingPathComponent("large"); try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: large)
        XCTAssertThrowsError(try document.load(large))
    }
    func testTreeOrderingHiddenFilesAndSymlinkTraversal() throws {
        let root = try folder(), directory = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: root)
        let visible = try WorkspaceFileListing.children(root, hidden: false)
        XCTAssertEqual(visible.map { $0.url.lastPathComponent }, ["Sources", "a.txt"])
        XCTAssertFalse(try WorkspaceFileListing.children(directory, hidden: false)[0].directory)
        XCTAssertEqual(WorkspaceFileListing.search(root, query: "a.txt", hidden: false).count, 1)
        XCTAssertEqual(try WorkspaceFileListing.children(root, hidden: true).count, 3)
    }
    func testSharedPalettesPreserveBuiltinsAndCustomFallbacks() throws {
        for style in AppColorTheme.allCases {
            for dark in [false, true] {
                let palette = ThemeColors(style: style, isDark: dark)
                XCTAssertEqual(palette.ansiColors.count, 16)
                XCTAssertNotEqual(palette.hex(for: .text), palette.hex(for: .canvas))
                var custom = CustomTheme(name: "Test", base: style)
                custom.dark.colors["accent"] = "#123456"
                let overridden = ThemeColors(style: .forest, isDark: dark, custom: custom)
                XCTAssertEqual(overridden.hex(for: .canvas), palette.hex(for: .canvas))
                XCTAssertEqual(overridden.hex(for: .accent), dark ? 0x123456 : palette.hex(for: .accent))
            }
        }
        XCTAssertEqual(ThemeColors(style: .dracula, isDark: true).hex(for: .canvas), 0x282A36)
    }
}
