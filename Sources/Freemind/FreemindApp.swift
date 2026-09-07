import SwiftUI
import AppKit
import FreemindCore
import SwiftTerm

@main
struct FreemindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    var body: some Scene {
        Window("Freemind", id: "main") {
            MainView(store: store).appAppearance(store: store, mainWindow: true)
        }.windowToolbarStyle(.unified).defaultSize(width: 1400, height: 900)
        .commands { FreemindCommands() }
        WindowGroup("Workspace", id: "workspace", for: String.self) { $id in
            Group {
                if let workspace = store.workspaces.first(where: { $0.id.uuidString == id }) {
                    WorkspaceView(workspace: workspace, standalone: true)
                } else { Text("Open this workspace from the main window.").padding(50) }
            }.appAppearance(store: store)
        }.windowToolbarStyle(.unified).defaultSize(width: 1200, height: 800)
        WindowGroup("Terminal", id: "terminal", for: String.self) { $key in
            DetachedTerminalWindow(store: store, key: key ?? "").appAppearance(store: store)
        }.defaultSize(width: 900, height: 650)
        Settings {
            SettingsView(store: store).appAppearance(store: store)
        }
    }
}
