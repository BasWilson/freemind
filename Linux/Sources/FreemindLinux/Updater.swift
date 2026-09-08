import Foundation
import FreemindCore
import LinuxUI

struct UpdateSnapshot: Sendable {
    var version = "Development"
    var explanation = "Automatic updates are available in signed Linux release installations."
    var message = "This development build is kept separate from release updates."
    var checks = true
    var downloads = true
    var canCheck = false
    var canDownload = false
}
private struct UpdatePreferences: Codable {
    var checks = true
    var downloads = true
    var manualDownload = false
    var lastCheck: Date?
    var lastError: String?
}
private struct UpdateResult: Decodable {
    var version: String?
    var available: Bool?
    var pending: Bool?
    var installed: Bool?
    var error: String?
}

actor LinuxUpdater {
    private var view = UpdateSnapshot()
    private var preferences = UpdatePreferences()
    private var preferencesURL: URL?
    private var releaseFolder: URL?
    private var busy = false
    private var pending = false
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?

    func snapshot() -> UpdateSnapshot { view }
    func start(configFolder: URL) async {
        guard preferencesURL == nil else { return }
        preferencesURL = configFolder.appendingPathComponent("updates.json")
        do {
            if FileManager.default.fileExists(atPath: preferencesURL!.path) { preferences = try DurableFile.load(UpdatePreferences.self, from: preferencesURL!) }
            view.checks = preferences.checks; view.downloads = preferences.downloads
            let folder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            if let data = try? Data(contentsOf: folder.appendingPathComponent("release.json")), let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                view.version = metadata["version"] as? String ?? "Development"
                if folder.deletingLastPathComponent().lastPathComponent == "versions" && FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.json").path) {
                    releaseFolder = folder; view.canCheck = true
                    pending = FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".updates/pending").path)
                    view.explanation = "Signed updates install when you quit. Terminal sessions stay running."
                    view.message = preferences.lastError ?? (pending ? "An update is ready to install when you quit." : "Updates come from the Freemind release feed.")
                    timer = Task { [weak self] in
                        while !Task.isCancelled {
                            await self?.automaticCheck()
                            try? await Task.sleep(for: .seconds(1800))
                        }
                    }
                } else {
                    view.explanation = "Update this installation through your package manager."
                    view.message = "Automatic installation is available for per-user release installations."
                }
            }
        } catch { view.message = error.localizedDescription }
        await publish()
    }
    func preference(key: String, enabled: Bool) async throws {
        guard let preferencesURL else { return }
        var updated = preferences
        if key == "checks" { updated.checks = enabled }
        else if key == "downloads" { updated.downloads = enabled; if !enabled { updated.manualDownload = false } }
        else { return }
        try DurableFile.save(updated, to: preferencesURL); preferences = updated
        view.checks = updated.checks; view.downloads = updated.downloads
        if !updated.checks { worker?.cancel() }
        await publish()
        if updated.checks { await automaticCheck() }
    }
    private func automaticCheck() async {
        guard preferences.checks, !busy, releaseFolder != nil, Date().timeIntervalSince(preferences.lastCheck ?? .distantPast) >= 86400 else { return }
        await request(download: false)
    }
    func request(download: Bool) async {
        guard !busy, releaseFolder != nil else { return }
        busy = true; view.canCheck = false; view.canDownload = false
        view.message = download ? "Downloading and verifying update…" : "Checking for updates…"
        await publish()
        worker = Task { [weak self] in await self?.perform(download: download) }
    }
    private func command(_ action: String) async throws -> UpdateResult {
        guard let releaseFolder else { throw FreemindError.message("This build uses package-manager updates.") }
        let result = try await CommandRunner.run("/usr/bin/python3", [releaseFolder.appendingPathComponent("update.py").path, action, "--directory", releaseFolder.path], timeout: 600)
        let decoded = try JSONDecoder().decode(UpdateResult.self, from: Data(result.output.utf8))
        if let error = decoded.error { throw FreemindError.message(error) }
        _ = try result.checked()
        return decoded
    }
    private func perform(download: Bool) async {
        do {
            var result = try await command(download ? "download" : "check")
            if download { preferences.manualDownload = true }
            if !download && result.available == true && preferences.checks && preferences.downloads {
                view.message = "Downloading and verifying Freemind \(result.version ?? "update")…"; await publish()
                try Task.checkCancellation()
                result = try await command("download")
            }
            pending = result.pending == true
            preferences.lastCheck = Date()
            if let preferencesURL { try DurableFile.save(preferences, to: preferencesURL) }
            view.canDownload = result.available == true && !pending
            view.message = pending ? "Freemind \(result.version ?? "update") is ready. It will install when you quit." : result.available == true ? "Freemind \(result.version ?? "update") is available." : "You’re up to date."
        } catch is CancellationError { view.message = "Update check cancelled." }
        catch { view.message = "Could not update: \(error.localizedDescription)" }
        busy = false; view.canCheck = releaseFolder != nil
        await publish()
    }
    func installOnQuit() async throws {
        // A download still in progress is left for a future run; quitting never
        // waits for the network. Installation itself is local and atomic.
        guard !busy, pending, (preferences.checks && preferences.downloads) || preferences.manualDownload else { return }
        do {
            _ = try await command("install"); pending = false; preferences.lastError = nil
        } catch {
            // Keep the installed version and let the user quit. Report the
            // failed local installation in Settings on their next launch.
            preferences.lastError = "The last update could not be installed: " + error.localizedDescription
        }
        if let preferencesURL { try? DurableFile.save(preferences, to: preferencesURL) }
    }
    private func publish() async {
        let state = view
        await onUI { fm_update_status(state.message, state.canCheck ? 1 : 0, state.canDownload ? 1 : 0) }
    }
}
