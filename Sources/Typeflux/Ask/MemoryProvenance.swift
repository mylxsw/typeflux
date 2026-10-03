import Foundation

/// Source identity is independent of the local conversation cache identity.
struct MemoryProvenance: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case explicit, correction, recent, soul }
    var id: String
    var source: Source
    var owner: String
    var scope: String
    var version: Int = 1
    var createdAt: Date
    var updatedAt: Date
    var expiry: Date?
    var supersedes: String?

    func isActive(owner: String, at date: Date) -> Bool {
        self.owner == owner && (expiry.map { $0 > date } ?? true)
    }
}

/// Durable owner-scoped tombstone for captured copies, including legacy snapshots
/// without provenance. Clearing a source cannot erase text already in history.
final class MemoryInvalidationStore: @unchecked Sendable {
    static let shared = MemoryInvalidationStore()
    private let defaults: UserDefaults
    private static let lock = NSLock()
    private let key = "ask.memory.invalidatedOwners.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func cutoff(owner: String) -> Date? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let time = (defaults.dictionary(forKey: key)?[owner] as? Double) else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    func invalidate(owner: String, at date: Date = Date(), notify: Bool = true) {
        Self.lock.lock()
        var values = defaults.dictionary(forKey: key) ?? [:]
        values[owner] = max(values[owner] as? Double ?? 0, date.timeIntervalSince1970)
        defaults.set(values, forKey: key)
        defaults.set(true, forKey: "ask.memory.purgePending." + owner)
        Self.lock.unlock()
        guard notify else { return }
        NotificationCenter.default.post(name: .askMemoryDidClear, object: nil, userInfo: ["owner": owner])
    }

    func permits(_ memory: AskMemory, owner: String) -> Bool {
        if let capturedOwner = memory.owner, capturedOwner != owner {
            return false
        }
        guard let cutoff = cutoff(owner: owner) else { return true }
        return memory.capturedAt.map { $0 > cutoff } ?? false
    }
}

/// Opt-in only after compatible API deployment and combined acceptance.
enum MemoryRollout {
    static let defaultsKey = "ask.memoryProvenanceEnabled"
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
