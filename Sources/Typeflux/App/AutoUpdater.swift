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

    private static let autoCheckInterval: TimeInterval = 3 * 3600

    private var websiteURL: URL? { URL(string: AppServerConfiguration.apiBaseURL) }
    private var initialAutoCheckWorkItem: DispatchWorkItem?
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
        let initialCheck = DispatchWorkItem { [weak self] in
            guard self?.settingsStore?.autoUpdateEnabled == true else { return }
            self?.checkForUpdates(manual: false)
        }
        initialAutoCheckWorkItem = initialCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: initialCheck)

        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.settingsStore?.autoUpdateEnabled == true else { return }
                self?.checkForUpdates(manual: false)
            }
        }
    }

    func stopAutoCheck() {
        initialAutoCheckWorkItem?.cancel()
        initialAutoCheckWorkItem = nil
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
    }

    // MARK: - Check

    func checkForUpdates(manual: Bool = true) {
        guard state == .idle else { return }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        Task { [weak self] in
            guard let self else { return }
            let executor = CloudRequestExecutor()
            do {
                let (data, _) = try await executor.execute { baseURL in
                    var components = URLComponents(url: AuthEndpointResolver.resolve(baseURL: baseURL, path: "/api/v1/app/update"), resolvingAgainstBaseURL: false) ?? URLComponents()
                    components.queryItems = [URLQueryItem(name: "version", value: currentVersion)]
                    let url = components.url ?? AuthEndpointResolver.resolve(baseURL: baseURL, path: "/api/v1/app/update")
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    return request
                }

                let envelope: UpdateEnvelope
                do {
                    envelope = try JSONDecoder().decode(UpdateEnvelope.self, from: data)
                } catch {
                    if manual { self.showCheckFailedAlert(message: error.localizedDescription) }
                    return
                }

                guard let info = envelope.data else {
                    if manual { self.showCheckFailedAlert(message: envelope.message ?? L("updater.checkFailed.noData")) }
                    return
                }

                if info.shouldUpdate {
                    self.prepareUpdate(info: info, manual: manual)
                } else if manual {
                    self.showUpToDateAlert()
                }
            } catch is CancellationError {
                return
            } catch {
                if manual { self.showCheckFailedAlert(message: error.localizedDescription) }
            }
        }
    }

    // MARK: - Download & Install

    private func prepareUpdate(info: UpdateInfo, manual: Bool) {
        // For auto-checks, skip if the user already dismissed this version in the current session
        if !manual, dismissedVersion == info.latestVersion { return }

        // Avoid stacking multiple alert windows
        guard updateAlertWindowController == nil else { return }

        guard let downloadURLString = info.downloadURL, !downloadURLString.isEmpty else {
            promptUpdate(info: info, downloadedArchiveURL: nil, sourceURL: nil)
            return
        }

        Task { [weak self] in
            await self?.downloadAndPrompt(info: info, downloadURLString: downloadURLString, manual: manual)
        }
    }

    private func downloadAndPrompt(info: UpdateInfo, downloadURLString: String, manual: Bool) async {
        guard state == .idle else { return }
        guard let downloadURL = URL(string: downloadURLString) else {
            if manual { showCheckFailedAlert(message: L("updater.checkFailed.noData")) }
            return
        }

        state = .downloading
        do {
            let tempFileURL = try await Self.downloadUpdate(from: downloadURL)
            state = .idle
            promptUpdate(info: info, downloadedArchiveURL: tempFileURL, sourceURL: downloadURL)
        } catch {
            state = .idle
            if manual { showCheckFailedAlert(message: error.localizedDescription) }
        }
    }

    private func promptUpdate(
        info: UpdateInfo,
        downloadedArchiveURL: URL?,
        sourceURL: URL?
    ) {
        let appearanceMode = settingsStore?.appearanceMode ?? .system
        let controller = UpdateAlertWindowController(
            version: info.latestVersion,
            releaseNotes: info.releaseNotes,
            releaseURL: info.releaseURL.flatMap(URL.init),
            appearanceMode: appearanceMode
        )
        controller.onAction = { [weak self, weak controller] action in
            self?.updateAlertWindowController = nil
            _ = controller  // silence unused-capture warning
            switch action {
            case .update:
                if let downloadedArchiveURL, let sourceURL {
                    Task {
                        await self?.installDownloadedUpdate(
                            archiveURL: downloadedArchiveURL,
                            sourceURL: sourceURL,
                            relaunch: true
                        )
                    }
                } else if let url = self?.websiteURL {
                    NSWorkspace.shared.open(url)
                } else {
                    self?.showCheckFailedAlert(message: L("updater.checkFailed.noData"))
                }
            case .skip:
                if let downloadedArchiveURL {
                    try? FileManager.default.removeItem(at: downloadedArchiveURL)
                }
                self?.dismissedVersion = info.latestVersion
            }
        }
        updateAlertWindowController = controller
        controller.show()
    }

    private func installDownloadedUpdate(archiveURL: URL, sourceURL: URL, relaunch: Bool) async {
        guard state == .idle else { return }
        state = .installing

        do {
            try await Task.detached(priority: .utility) {
                try AutoUpdater.performInstall(from: archiveURL, sourceURL: sourceURL, relaunch: relaunch)
            }.value

            NSApp.terminate(nil)
        } catch {
            state = .idle
            showCheckFailedAlert(message: error.localizedDescription)
        }
    }

    private static func downloadUpdate(from downloadURL: URL) async throws -> URL {
        do {
            return try await downloadFile(from: downloadURL)
        } catch {
            guard let proxyURL = GitHubProxyDownloadURL.proxyURL(for: downloadURL) else {
                throw error
            }

            NetworkDebugLogger.logError(
                context: "Auto update download failed; retrying through GitHub proxy",
                error: error,
            )
            return try await downloadFile(from: proxyURL)
        }
    }

    private static func downloadFile(from url: URL) async throws -> URL {
        let (tempFileURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw UpdateError.downloadFailed
        }
        return tempFileURL
    }

    // Runs off the main actor — only does file I/O and process launching.
    nonisolated private static func performInstall(from archiveURL: URL, sourceURL: URL, relaunch: Bool) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("typeflux-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            let newAppURL: URL
            switch AutoUpdateArchiveInstaller.archiveKind(for: sourceURL) {
            case .dmg:
                newAppURL = try AutoUpdateArchiveInstaller.extractAppFromDMG(archiveURL, into: tempDir)
            case .zip:
                newAppURL = try AutoUpdateArchiveInstaller.extractAppFromZip(archiveURL, into: tempDir)
            }

            guard fm.fileExists(atPath: newAppURL.path) else {
                throw UpdateError.appNotFound
            }
            try AutoUpdateArchiveInstaller.verifyCodeSignature(of: newAppURL)
            try? fm.removeItem(at: archiveURL)

            let scriptURL = fm.temporaryDirectory.appendingPathComponent("typeflux_relaunch_\(UUID().uuidString).sh")
            let script = AutoUpdateArchiveInstaller.relaunchScript(
                currentAppURL: Bundle.main.bundleURL,
                newAppURL: newAppURL,
                cleanupURL: tempDir,
                currentProcessIdentifier: getpid(),
                relaunch: relaunch
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
            launcher.arguments = [scriptURL.path]
            try launcher.run()
            // launcher runs detached; do not wait
        } catch {
            try? fm.removeItem(at: tempDir)
            throw error
        }
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
    case downloadFailed
    case signatureVerificationFailed

    var errorDescription: String? {
        switch self {
        case .extractionFailed: L("updater.install.extractionFailed")
        case .appNotFound: L("updater.install.appNotFound")
        case .downloadFailed: L("updater.download.failed")
        case .signatureVerificationFailed: L("updater.install.signatureVerificationFailed")
        }
    }
}

enum AutoUpdateArchiveKind: Equatable {
    case zip
    case dmg
}

enum AutoUpdateArchiveInstaller {
    static func archiveKind(for sourceURL: URL) -> AutoUpdateArchiveKind {
        sourceURL.pathExtension.lowercased() == "dmg" ? .dmg : .zip
    }

    static func extractAppFromZip(_ zipURL: URL, into tempDir: URL) throws -> URL {
        let extractDir = tempDir.appendingPathComponent("zip")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let status = try runProcess(
            executablePath: "/usr/bin/ditto",
            arguments: ["-xk", zipURL.path, extractDir.path]
        )
        guard status == 0 else {
            throw UpdateError.extractionFailed
        }

        return try findAppBundle(in: extractDir)
    }

    static func extractAppFromDMG(_ dmgURL: URL, into tempDir: URL) throws -> URL {
        let mountPoint = tempDir.appendingPathComponent("mount")
        let stagingDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let attachStatus = try runProcess(
            executablePath: "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard attachStatus == 0 else {
            throw UpdateError.extractionFailed
        }
        defer {
            _ = try? runProcess(
                executablePath: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint.path, "-quiet", "-force"],
                timeout: 10
            )
        }

        let mountedAppURL = try findAppBundle(in: mountPoint)
        let stagedAppURL = stagingDir.appendingPathComponent(mountedAppURL.lastPathComponent)
        try FileManager.default.copyItem(at: mountedAppURL, to: stagedAppURL)
        return stagedAppURL
    }

    static func findAppBundle(in rootURL: URL) throws -> URL {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateError.appNotFound
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "app" else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                enumerator.skipDescendants()
                return url
            }
        }

        throw UpdateError.appNotFound
    }

    static func verifyCodeSignature(of appURL: URL) throws {
        let status = try runProcess(
            executablePath: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
        guard status == 0 else {
            throw UpdateError.signatureVerificationFailed
        }
    }

    static func relaunchScript(
        currentAppURL: URL,
        newAppURL: URL,
        cleanupURL: URL? = nil,
        currentProcessIdentifier: pid_t? = nil,
        relaunch: Bool
    ) -> String {
        let currentAppPath = shellSingleQuoted(currentAppURL.path)
        let newAppPath = shellSingleQuoted(newAppURL.path)
        let cleanupPath = shellSingleQuoted(cleanupURL?.path ?? "")
        let currentPID = currentProcessIdentifier.map(String.init) ?? ""
        var scriptLines = """
        #!/bin/bash
        set -e
        current_app=\(currentAppPath)
        new_app=\(newAppPath)
        cleanup_dir=\(cleanupPath)
        current_pid='\(currentPID)'
        backup_app="${current_app}.typeflux-backup.$$"

        if [ -n "$current_pid" ]; then
          for _ in $(seq 1 30); do
            if ! kill -0 "$current_pid" 2>/dev/null; then
              break
            fi
            sleep 1
          done
        fi

        restore_current() {
          if [ -e "$backup_app" ] && [ ! -e "$current_app" ]; then
            mv "$backup_app" "$current_app"
          fi
        }

        if [ -e "$current_app" ]; then
          rm -rf "$backup_app"
          mv "$current_app" "$backup_app"
        fi

        if ! mv "$new_app" "$current_app"; then
          restore_current
          exit 1
        fi

        rm -rf "$backup_app"
        xattr -dr com.apple.quarantine "$current_app" 2>/dev/null || true
        """
        if relaunch {
            scriptLines += "\nopen \"$current_app\""
        }
        scriptLines += """

        if [ -n "$cleanup_dir" ]; then
          rm -rf "$cleanup_dir"
        fi
        rm -f "$0"
        """
        return scriptLines
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @discardableResult
    private static func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        try process.run()

        guard let timeout else {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return 124
        }
        return process.terminationStatus
    }
}

enum GitHubProxyDownloadURL {
    static let proxyBaseURL = URL(string: "https://gh-proxy.com")!

    static func proxyURL(for url: URL) -> URL? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        return URL(string: "\(proxyBaseURL.absoluteString)/\(url.absoluteString)")
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
    let releaseURL: String?

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version"
        case releaseNotes = "release_notes"
        case shouldUpdate = "should_update"
        case downloadURL = "download_url"
        case releaseURL = "release_url"
    }
}
