import Foundation

enum DevLauncher {
    static func relaunchAsAppBundleIfNeeded() {
        guard !PrivacyGuard.isRunningInAppBundle else { return }

        // When running via `swift run`, TCC may abort the process when accessing microphone/speech.
        // We relaunch as a minimal .app bundle to ensure Info.plist privacy keys exist.
        guard let projectRoot = findProjectRoot() else {
            NSLog("[DevLauncher] Could not find project root")
            return
        }

        let scriptURL = projectRoot.appendingPathComponent("scripts/run_dev_app.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            NSLog("[DevLauncher] Missing executable script: \(scriptURL.path)")
            return
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.currentDirectoryURL = projectRoot
            try process.run()
        } catch {
            NSLog("[DevLauncher] Failed to launch app bundle: \(error)")
        }

        // Exit the `swift run` process; the app bundle will run separately.
        exit(0)
    }

    private static func findProjectRoot() -> URL? {
        // Try current working directory first
        let cwd = FileManager.default.currentDirectoryPath
        let cwdURL = URL(fileURLWithPath: cwd)
        if FileManager.default.fileExists(atPath: cwdURL.appendingPathComponent("Package.swift").path) {
            return cwdURL
        }

        // Try executable path and walk up
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0 ..< 10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        return nil
    }
}
