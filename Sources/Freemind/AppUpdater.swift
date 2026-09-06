import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    private let controller: SPUStandardUpdaterController?
    private var started = false

    var isConfigured: Bool { controller != nil }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    private init() {
        // Local builds without a release feed must not contact a placeholder URL
        // or replace a developer's build with the public release.
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
    }

    func start() {
        guard !started, let controller else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Software Updates").font(.headline)
            Text("Version \(updater.version)").foregroundStyle(.secondary)
            if updater.isConfigured {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
                Toggle("Download and install updates when quitting", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticDownloads))
                    .disabled(!updater.automaticallyChecksForUpdates)
                CheckForUpdatesButton()
            } else {
                Text("Automatic updates are available in builds downloaded from GitHub Releases.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
