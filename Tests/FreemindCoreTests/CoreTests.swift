import XCTest
@testable import FreemindCore

final class CoreTests: XCTestCase {
    func testArgumentsRemainLiteral() throws {
        XCTAssertEqual(CodexOptions.toml("/a b/c"), "\"/a b/c\"")
        XCTAssertEqual(try ArgumentTokenizer.parse("--model 'a b' --config 'x=\"$(touch bad)\"'"), ["--model", "a b", "--config", "x=\"$(touch bad)\""])
        XCTAssertThrowsError(try ArgumentTokenizer.parse("--model 'unfinished"))
    }
    func testSplitRemovalRetainsOtherPanes() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = LayoutNode.pane(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        XCTAssertEqual(layout.removing(b)?.paneIDs, [a, c])
    }
    func testWorkspacePortableAndRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = WorkspacePaths(root: folder)
        try paths.initialize()
        var item = try DurableFile.load(WorkspaceDefinition.self, from: paths.definition)
        item.name = "Updated"; try DurableFile.save(item, to: paths.definition)
        try Data("corrupt".utf8).write(to: paths.definition)
        XCTAssertEqual(try DurableFile.load(WorkspaceDefinition.self, from: paths.definition).name, folder.lastPathComponent)
        XCTAssertEqual(paths.relative(folder.appendingPathComponent("src/a.swift")), "src/a.swift")
        XCTAssertTrue(try String(contentsOf: paths.metadata.appendingPathComponent(".gitignore")).contains("/local/"))
    }
    func testExternalEditsAreDetected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("initial".utf8).write(to: url)
        let initial = try Data(contentsOf: url)
        try Data("external".utf8).write(to: url)
        XCTAssertThrowsError(try DurableFile.saveText("mine", to: url, expected: initial))
        XCTAssertEqual(try String(contentsOf: url), "external")
    }
    func testHooksDoNotStorePromptOrToolArguments() throws {
        let input = Data("{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"PRIVATE\",\"session_id\":\"\(UUID().uuidString)\"}".utf8)
        let event = try HookEvent.parse(input)
        let encoded = String(decoding: try DurableFile.encoder.encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE")); XCTAssertEqual(event.status, "Working")
    }
}

extension CoreTests {
    func testBalancedResponsivePaneGrid() {
        XCTAssertEqual(PaneGrid(count: 2, width: 1600).columns, 2)
        XCTAssertEqual(PaneGrid(count: 3, width: 1600).columns, 2)
        XCTAssertEqual(PaneGrid(count: 3, width: 1600).rows, 2)
        XCTAssertEqual(PaneGrid(count: 4, width: 1600).columns, 2)
        XCTAssertEqual(PaneGrid(count: 4, width: 1600).rows, 2)
        XCTAssertEqual(PaneGrid(count: 9, width: 1400).columns, 3)
        XCTAssertEqual(PaneGrid(count: 16, width: 1600).columns, 4)
        XCTAssertEqual(PaneGrid(count: 16, width: 800).columns, 2)
        XCTAssertEqual(PaneGrid(count: 3, width: 600).columns, 1)
    }
}
