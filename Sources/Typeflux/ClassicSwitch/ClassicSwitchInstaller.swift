import Foundation

/// A verified Classic app waiting in a temporary directory.
struct ClassicStagedApp: Equatable, Sendable {
    let appURL: URL
    let workingDirectory: URL
}

enum ClassicSwitchInstallError: LocalizedError, Equatable {
    case checksumMismatch

    var errorDescription: String? { L("updater.install.signatureVerificationFailed") }
}

protocol ClassicSwitchInstalling: Sendable {
    /// Checks the archive, extracts the app and verifies its signature, Bundle ID and Team ID.
    func stage(archiveURL: URL, package: ClassicPackage) async throws -> ClassicStagedApp
    /// Hands the staged app to the relaunch script; the caller terminates the app next.
    func launchReplacement(_ staged: ClassicStagedApp) throws
    func discard(_ staged: ClassicStagedApp)
}

/// Reuses the `AutoUpdater` extraction, signature check and relaunch script.
struct AutoUpdaterClassicSwitchInstaller: ClassicSwitchInstalling {
    var currentIdentity: @Sendable () throws -> ClassicSigningIdentity = { try ClassicBundleVerifier.currentIdentity() }
    var candidateIdentity: @Sendable (URL) throws -> ClassicSigningIdentity = { try ClassicBundleVerifier.identity(ofAppAt: $0) }
    var verifyCodeSignature: @Sendable (URL) throws -> Void = { try AutoUpdateArchiveInstaller.verifyCodeSignature(of: $0) }

    func stage(archiveURL: URL, package: ClassicPackage) async throws -> ClassicStagedApp {
        try await Task.detached(priority: .userInitiated) {
            try stageSynchronously(archiveURL: archiveURL, package: package)
        }.value
    }

    func stageSynchronously(archiveURL: URL, package: ClassicPackage) throws -> ClassicStagedApp {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archiveURL) }
        if let expected = package.sha256 {
            guard try ClassicBundleVerifier.sha256(ofFileAt: archiveURL) == expected else {
                throw ClassicSwitchInstallError.checksumMismatch
            }
        }
        let workingDirectory = fm.temporaryDirectory.appendingPathComponent("typeflux-classic-switch-\(UUID().uuidString)")
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            let appURL = try AutoUpdateArchiveInstaller.extractAppFromZip(archiveURL, into: workingDirectory)
            try verifyCodeSignature(appURL)
            try ClassicBundleVerifier.verify(candidate: candidateIdentity(appURL), current: currentIdentity())
            return ClassicStagedApp(appURL: appURL, workingDirectory: workingDirectory)
        } catch {
            try? fm.removeItem(at: workingDirectory)
            throw error
        }
    }

    func launchReplacement(_ staged: ClassicStagedApp) throws {
        try AutoUpdateArchiveInstaller.launchReplacement(
            newAppURL: staged.appURL,
            cleanupURL: staged.workingDirectory,
            relaunch: true
        )
    }

    func discard(_ staged: ClassicStagedApp) {
        try? FileManager.default.removeItem(at: staged.workingDirectory)
    }
}
