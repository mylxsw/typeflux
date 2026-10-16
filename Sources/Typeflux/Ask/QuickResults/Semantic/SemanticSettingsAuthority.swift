import Foundation

/// A process-local receipt for an accepted settings edit. No settings are read
/// by the off-actor consumer; delayed or repeated receipts cannot revoke a later bind.
struct SemanticSettingsChange: Sendable {
    private final class Sequence: @unchecked Sendable {
        let lock = NSLock()
        var revision: UInt64 = 0
        func next() -> UInt64 { lock.withLock { revision += 1; return revision } }
        func current() -> UInt64 { lock.withLock { revision } }
    }
    private static let sequence = Sequence()
    static let notification = Notification.Name("SettingsStore.semanticScopeWillChange")
    let revision: UInt64
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint; revision = Self.sequence.next()
    }

    static var currentRevision: UInt64 { sequence.current() }
}

/// Owns only revocation of the original token. It never starts or retries work.
final class SemanticSettingsAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var lifecycle: AskSearchCancellation?
    private var fingerprint: String?

    func bind(_ lifecycle: AskSearchCancellation, fingerprint: String) {
        lock.withLock {
            self.lifecycle = lifecycle; self.fingerprint = fingerprint
            revision = SemanticSettingsChange.currentRevision
        }
    }

    func receive(_ change: SemanticSettingsChange) {
        lock.withLock {
            guard change.revision > revision else { return }
            revision = change.revision
            if fingerprint != change.fingerprint { lifecycle?.cancel() }
        }
    }
}

extension SettingsStore {
    func semanticScopeFingerprint(enabled: Bool? = nil, names: AskLauncherSearchSettings? = nil,
                                  fileSearchEnabled: Bool? = nil) -> String {
        "\(enabled ?? semanticFileSearch.enabled)\u{3}\((names ?? askLauncherSearchSettings).fileIndexFingerprint)\u{3}\(fileSearchEnabled ?? askQuickFileSearchEnabled)"
    }

    /// Revoke before persistence and before the ordinary, asynchronously consumed
    /// UI notification. Direct defaults writes and OS permission changes remain
    /// outside this settings-setter contract.
    func revokeSemanticScope(before fingerprint: String) {
        guard fingerprint != semanticScopeFingerprint() else { return }
        NotificationCenter.default.post(name: SemanticSettingsChange.notification, object: self,
                                        userInfo: ["change": SemanticSettingsChange(fingerprint: fingerprint)])
    }
}
