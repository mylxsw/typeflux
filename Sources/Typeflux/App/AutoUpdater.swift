import AppKit
import Foundation

extension Notification.Name {
    static let autoUpdateStateDidChange = Notification.Name("AutoUpdater.stateDidChange")
}

@MainActor
final class AutoUpdater {
    static let shared = AutoUpdater()

    enum State: Equatable {
        case idle
        case downloading
        case installing
    }

    private(set) var state: State = .idle {
        didSet {
            NotificationCenter.default.post(name: .autoUpdateStateDidChange, object: self)
        }
    }

    private static let defaultBaseURL = "https://typeflux.gulu.ai"
    private static let autoCheckInterval: TimeInterval = 3 * 3600

    private var apiBaseURL: String {
        ProcessInfo.processInfo.environment["TYPEFLUX_API_URL"] ?? Self.defaultBaseURL
    }

    private var websiteURL: URL { URL(string: apiBaseURL)! }
    private var autoCheckTimer: Timer?
    private weak var settingsStore: SettingsStore?

    /// Version that the user dismissed via "暂不更新" in the current session.
    /// Resets on app restart; ignored for manual checks.
    private var dismissedVersion: String?
    private var updateAlertWindowController: UpdateAlertWindowController?

    private init() {}

    // MARK: - Auto-check

    func startAutoCheck(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        stopAutoCheck()
        guard settingsStore.autoUpdateEnabled else { return }

        // Initial check after a short delay on app launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard self?.settingsStore?.autoUpdateEnabled == true else { return }
            self?.checkForUpdates(manual: false)
        }

        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.settingsStore?.autoUpdateEnabled == true else { return }
                self?.checkForUpdates(manual: false)
            }
        }
    }

    func stopAutoCheck() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
    }

    // MARK: - Check

    func checkForUpdates(manual: Bool = true) {
        guard state == .idle else { return }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        guard var components = URLComponents(string: "\(apiBaseURL)/api/v1/app/update") else { return }
        components.queryItems = [URLQueryItem(name: "version", value: currentVersion)]
        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    if manual { self.showCheckFailedAlert(message: error.localizedDescription) }
                    return
                }

                guard let data else {
                    if manual { self.showCheckFailedAlert(message: L("updater.checkFailed.noData")) }
                    return
                }

                do {
                    let envelope = try JSONDecoder().decode(UpdateEnvelope.self, from: data)
                    guard let info = envelope.data else {
                        if manual { self.showCheckFailedAlert(message: envelope.message ?? L("updater.checkFailed.noData")) }
                        return
                    }

                    if info.shouldUpdate {
                        self.promptUpdate(info: info, manual: manual)
                    } else if manual {
                        self.showUpToDateAlert()
                    }
                } catch {
                    if manual { self.showCheckFailedAlert(message: error.localizedDescription) }
                }
            }
        }.resume()
    }

    // MARK: - Download & Install

    private func promptUpdate(info: UpdateInfo, manual: Bool) {
        // For auto-checks, skip if the user already dismissed this version in the current session
        if !manual, dismissedVersion == info.latestVersion { return }

        // Avoid stacking multiple alert windows
        guard updateAlertWindowController == nil else { return }

        let appearanceMode = settingsStore?.appearanceMode ?? .system
        let controller = UpdateAlertWindowController(
            version: info.latestVersion,
            releaseNotes: info.releaseNotes,
            appearanceMode: appearanceMode
        )
        controller.onAction = { [weak self, weak controller] action in
            self?.updateAlertWindowController = nil
            _ = controller  // silence unused-capture warning
            switch action {
            case .update:
                if let urlString = info.downloadURL, !urlString.isEmpty {
                    Task { await self?.downloadAndInstall(info: info, downloadURLString: urlString) }
                } else if let self {
                    NSWorkspace.shared.open(self.websiteURL)
                }
            case .skip:
                self?.dismissedVersion = info.latestVersion
            }
        }
        updateAlertWindowController = controller
        controller.show()
    }

    private func downloadAndInstall(info: UpdateInfo, downloadURLString: String) async {
        guard state == .idle else { return }
        guard let downloadURL = URL(string: downloadURLString) else {
            showCheckFailedAlert(message: L("updater.checkFailed.noData"))
            return
        }

        state = .downloading

        do {
            let (tempFileURL, _) = try await URLSession.shared.download(from: downloadURL)

            state = .installing

            try await Task.detached(priority: .utility) {
                try AutoUpdater.performInstall(from: tempFileURL)
            }.value

            NSApp.terminate(nil)
        } catch {
            state = .idle
            showCheckFailedAlert(message: error.localizedDescription)
        }
    }

    // Runs off the main actor — only does file I/O and process launching.
    nonisolated private static func performInstall(from zipURL: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("typeflux-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Extract zip with ditto
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipURL.path, tempDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        // Find the .app bundle in the extracted directory
        let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey])
        guard let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        let currentAppPath = Bundle.main.bundleURL.path
        let newAppPath = newAppURL.path

        // Write a short shell script that replaces the app after this process exits
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("typeflux_relaunch_\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf '\(currentAppPath)'
        mv '\(newAppPath)' '\(currentAppPath)'
        xattr -dr com.apple.quarantine '\(currentAppPath)' 2>/dev/null
        open '\(currentAppPath)'
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptURL.path]
        try launcher.run()
        // launcher runs detached; do not wait
    }

    // MARK: - Alerts

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L("updater.latest.title")
        alert.informativeText = L("updater.latest.message")
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }

    private func showCheckFailedAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = L("updater.checkFailed.title")
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }
}

// MARK: - Errors

private enum UpdateError: LocalizedError {
    case extractionFailed
    case appNotFound

    var errorDescription: String? {
        switch self {
        case .extractionFailed: L("updater.install.extractionFailed")
        case .appNotFound: L("updater.install.appNotFound")
        }
    }
}

// MARK: - Response models

private struct UpdateEnvelope: Decodable {
    let code: String?
    let message: String?
    let data: UpdateInfo?
}

private struct UpdateInfo: Decodable {
    let latestVersion: String
    let releaseNotes: String
    let shouldUpdate: Bool
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version"
        case releaseNotes = "release_notes"
        case shouldUpdate = "should_update"
        case downloadURL = "download_url"
    }
}
