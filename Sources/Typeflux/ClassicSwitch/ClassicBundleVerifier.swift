import CryptoKit
import Foundation
import Security

/// The identity macOS uses to keep data and permissions with an app: its bundle identifier and the
/// signing team. Self-signed development builds have no team, so their leaf certificate stands in.
struct ClassicSigningIdentity: Equatable, Sendable {
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let leafCertificateSHA256: String?
}

enum ClassicBundleVerificationError: LocalizedError, Equatable {
    case bundleIdentifierMismatch
    case teamIdentifierMismatch
    case signatureUnreadable

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierMismatch, .teamIdentifierMismatch: L("classic.switch.error.identity")
        case .signatureUnreadable: L("updater.install.signatureVerificationFailed")
        }
    }
}

enum ClassicBundleVerifier {
    /// Rejects any downloaded app that would not inherit this app's data, Keychain and permissions.
    static func verify(candidate: ClassicSigningIdentity, current: ClassicSigningIdentity) throws {
        guard let currentBundleID = current.bundleIdentifier, !currentBundleID.isEmpty,
              candidate.bundleIdentifier == currentBundleID
        else { throw ClassicBundleVerificationError.bundleIdentifierMismatch }

        if let currentTeam = current.teamIdentifier, !currentTeam.isEmpty {
            guard candidate.teamIdentifier == currentTeam else {
                throw ClassicBundleVerificationError.teamIdentifierMismatch
            }
            return
        }
        // No team: only a build signed with the very same certificate is accepted. Ad-hoc builds
        // carry no certificate and never match.
        guard candidate.teamIdentifier == nil,
              let currentLeaf = current.leafCertificateSHA256,
              candidate.leafCertificateSHA256 == currentLeaf
        else { throw ClassicBundleVerificationError.teamIdentifierMismatch }
    }

    static func identity(ofAppAt url: URL) throws -> ClassicSigningIdentity {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw ClassicBundleVerificationError.signatureUnreadable
        }
        return try identity(of: staticCode, bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
    }

    static func currentIdentity() throws -> ClassicSigningIdentity {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { throw ClassicBundleVerificationError.signatureUnreadable }
        return try identity(of: staticCode, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private static func identity(of code: SecStaticCode, bundleIdentifier: String?) throws -> ClassicSigningIdentity {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let info = information as? [String: Any]
        else { throw ClassicBundleVerificationError.signatureUnreadable }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first.map { certificate in
            SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        }
        return ClassicSigningIdentity(bundleIdentifier: bundleIdentifier, teamIdentifier: team, leafCertificateSHA256: leaf)
    }

    /// Streams the archive through SHA-256 so large packages are not loaded into memory.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
