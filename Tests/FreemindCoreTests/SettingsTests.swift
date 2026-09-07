import XCTest
@testable import FreemindCore

final class SettingsTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freemind-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testSettingsPersistIndependentTerminalAppearanceAndWorkspaceOptions() throws {
        let url = try temporaryFolder().appendingPathComponent("app/settings.json")
        XCTAssertEqual(try AppSettings.load(from: url), AppSettings())
        var settings = AppSettings()
        settings.appearance = .light; settings.theme = .forest
        settings.terminalAppearance = .dark; settings.terminalTheme = .ocean
        settings.customThemeID = "my-app-theme"; settings.terminalCustomThemeID = "my-terminal-theme"
        settings.workspaceDefaults.model = "custom-model"
        settings.workspaceDefaults.profile = "development"
        settings.workspaceDefaults.reasoning = "high"
        settings.workspaceDefaults.sandbox = "workspace-write"
        settings.workspaceDefaults.approval = "on-request"
        settings.workspaceDefaults.additionalDirectories = ["/a folder/shared"]
        settings.workspaceDefaults.configOverrides = ["features.example=true"]
        settings.workspaceDefaults.extraArguments = "--enable 'example feature'"
        settings.workspaceDefaults.automaticallyTrustWorkspace = false
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), settings)
        XCTAssertEqual(try AppSettings.load(from: url).workspaceDefaults.arguments(), try settings.workspaceDefaults.arguments())
    }

    func testMissingAndUnknownAppearanceValuesKeepCompatibleDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)), AppSettings())
        let unknown = Data(#"{"appearance":"future","theme":"future","terminalAppearance":"future","terminalTheme":"future"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: unknown), AppSettings())
        var settings = AppSettings(); settings.terminalAppearance = .dark
        let decoded = try JSONDecoder().decode(AppSettings.self, from: DurableFile.encoder.encode(settings))
        XCTAssertNil(decoded.terminalTheme)
        XCTAssertEqual(decoded.terminalAppearance, .dark)
    }

    func testInvalidDefaultsDoNotReplaceSavedSettings() throws {
        let url = try temporaryFolder().appendingPathComponent("settings.json")
        var saved = AppSettings(); saved.theme = .violet
        try saved.save(to: url)
        var invalid = saved; invalid.workspaceDefaults.extraArguments = "--model 'unfinished"
        XCTAssertThrowsError(try invalid.save(to: url))
        invalid = saved; invalid.workspaceDefaults.configOverrides = ["missing equals"]
        XCTAssertThrowsError(try invalid.save(to: url))
        XCTAssertEqual(try AppSettings.load(from: url), saved)
    }

    func testSettingsRecoverFromBackupAndReportUnrecoverableCorruption() throws {
        let url = try temporaryFolder().appendingPathComponent("settings.json")
        var settings = AppSettings(); settings.theme = .ocean
        try settings.save(to: url)
        let previous = settings
        settings.theme = .violet; try settings.save(to: url)
        try Data("broken".utf8).write(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), previous)
        try FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
        XCTAssertThrowsError(try AppSettings.load(from: url))
    }

    func testGlobalDefaultsSeedNewWorkspacesAndPreserveExistingWorkspacesAndPanes() throws {
        let folder = try temporaryFolder()
        var global = CodexOptions(); global.model = "global-model"; global.automaticallyTrustWorkspace = false
        let first = WorkspacePaths(root: folder)
        try first.initialize(defaults: global)
        var workspace = try DurableFile.load(WorkspaceDefinition.self, from: first.definition)
        XCTAssertEqual(workspace.defaults, global)
        workspace.defaults.profile = "project-specific"
        try DurableFile.save(workspace, to: first.definition)
        var layout = WorkspaceLayout()
        layout.panes = [PaneDefinition(title: "Existing", options: workspace.defaults)]
        try DurableFile.save(layout, to: first.layout)

        global.model = "new-global-model"; global.automaticallyTrustWorkspace = true
        try first.initialize(defaults: global)
        XCTAssertEqual(try DurableFile.load(WorkspaceDefinition.self, from: first.definition), workspace)
        XCTAssertEqual(try DurableFile.load(WorkspaceLayout.self, from: first.layout), layout)

        let newFolder = folder.appendingPathComponent("new workspace")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let second = WorkspacePaths(root: newFolder)
        try second.initialize(defaults: global)
        XCTAssertEqual(try DurableFile.load(WorkspaceDefinition.self, from: second.definition).defaults, global)
    }
}
