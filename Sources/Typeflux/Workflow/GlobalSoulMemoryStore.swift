import Foundation

struct GlobalSoulMemory: Codable, Equatable {
    let text: String
    let updatedAt: Date
}

struct GlobalSoulInput: Codable, Equatable {
    let id: UUID
    let ownerID: String
    let appIdentifier: String
    let text: String
    let recordedAt: Date
}

struct GlobalSoulBatch {
    let inputs: [GlobalSoulInput]
    let previousSoul: String
    let ownerID: String
    let generation: Int
}

/// A separate four-hour queue prevents surrounding editor context and unverified
/// delivery baselines from becoming long-term memory.
final class GlobalSoulMemoryStore: @unchecked Sendable {
    static let shared = GlobalSoulMemoryStore()
    static let maximumInputLength = 500
    static let maximumSoulLength = 500
    static let batchSize = 20
    static let minimumExpiryBatchSize = 5
    static let pendingLifetime: TimeInterval = 4 * 60 * 60
    static let preExpiryInterval: TimeInterval = 10 * 60

    private struct State: Codable {
        var souls: [String: GlobalSoulMemory] = [:]
        var pending: [GlobalSoulInput] = []
    }

    private let lock = NSLock()
    private let fileURL: URL
    private var state: State
    private var generation = 0

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("global-soul-memory.json")
        state = (try? Data(contentsOf: self.fileURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State()
    }

    func soul(ownerID: String) -> GlobalSoulMemory? {
        lock.lock()
        defer { lock.unlock() }
        return state.souls[ownerID]
    }

    func pendingAppIdentifiers(ownerID: String, at date: Date = Date()) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        return Array(Set(state.pending.filter { $0.ownerID == ownerID }.map(\.appIdentifier))).sorted()
    }

    func recordFinalInput(
        id: UUID, ownerID: String, appIdentifier: String, text: String, at date: Date = Date()
    ) {
        let body = Self.compactInput(text)
        guard !ownerID.isEmpty, !appIdentifier.isEmpty, !body.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        guard !state.pending.contains(where: { $0.id == id }) else { return }
        state.pending.append(GlobalSoulInput(
            id: id, ownerID: ownerID, appIdentifier: appIdentifier, text: body, recordedAt: date
        ))
        persist()
    }

    static func compactInput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumInputLength else { return trimmed }
        let marker = " … "
        let headCount = (maximumInputLength - marker.count) / 2
        let tailCount = maximumInputLength - marker.count - headCount
        return String(trimmed.prefix(headCount)) + marker + String(trimmed.suffix(tailCount))
    }

    func readyBatch(ownerID: String, allowedApps: Set<String>? = nil, at date: Date = Date()) -> GlobalSoulBatch? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        // Filter excluded apps without changing their pending state; disabling an
        // app does not silently consume or promote its earlier inputs.
        let inputs = state.pending.filter { input in
            input.ownerID == ownerID && (allowedApps.map { $0.contains(input.appIdentifier) } ?? true)
        }.sorted { $0.recordedAt < $1.recordedAt }
        guard let oldest = inputs.first else { return nil }
        let count = inputs.count
        guard count >= Self.batchSize || (
            count >= Self.minimumExpiryBatchSize
                && date.timeIntervalSince(oldest.recordedAt) >= Self.pendingLifetime - Self.preExpiryInterval
        ) else { return nil }
        return GlobalSoulBatch(
            inputs: Array(inputs.prefix(Self.batchSize)),
            previousSoul: state.souls[ownerID]?.text ?? "",
            ownerID: ownerID,
            generation: generation
        )
    }

    func nextWake(ownerID: String, allowedApps: Set<String>? = nil, at date: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        let inputs = state.pending.filter { input in
            input.ownerID == ownerID && (allowedApps.map { $0.contains(input.appIdentifier) } ?? true)
        }.sorted { $0.recordedAt < $1.recordedAt }
        guard let oldest = inputs.first else { return nil }
        if inputs.count >= Self.batchSize { return date }
        let expiry = oldest.recordedAt.addingTimeInterval(Self.pendingLifetime)
        if inputs.count >= Self.minimumExpiryBatchSize {
            let consolidation = expiry.addingTimeInterval(-Self.preExpiryInterval)
            if date < consolidation { return consolidation }
        }
        return expiry
    }

    func nextExpiry(ownerID: String, at date: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        return state.pending.filter { $0.ownerID == ownerID }
            .map { $0.recordedAt.addingTimeInterval(Self.pendingLifetime) }
            .min()
    }

    @discardableResult
    func complete(_ batch: GlobalSoulBatch, with text: String, at date: Date = Date()) -> Bool {
        let soul = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumSoulLength))
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        guard generation == batch.generation,
              (state.souls[batch.ownerID]?.text ?? "") == batch.previousSoul,
              batch.inputs.allSatisfy({ input in
                  state.pending.contains(where: { $0.id == input.id && $0 == input })
              })
        else { return false }
        var updated = state
        let consumed = Set(batch.inputs.map(\.id))
        updated.pending.removeAll { consumed.contains($0.id) }
        if soul.isEmpty {
            updated.souls.removeValue(forKey: batch.ownerID)
        } else {
            updated.souls[batch.ownerID] = GlobalSoulMemory(text: soul, updatedAt: date)
        }
        guard persist(updated) else { return false }
        state = updated
        return true
    }

    @discardableResult
    func deleteSoul(ownerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var updated = state
        updated.souls.removeValue(forKey: ownerID)
        updated.pending.removeAll { $0.ownerID == ownerID }
        guard persist(updated) else { return false }
        state = updated
        generation += 1
        return true
    }

    func removeInput(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard state.pending.contains(where: { $0.id == id }) else { return }
        generation += 1
        state.pending.removeAll { $0.id == id }
        persist()
    }

    func clearPending(appIdentifier: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        if let appIdentifier {
            state.pending.removeAll { $0.appIdentifier == appIdentifier }
        } else {
            state.pending.removeAll()
        }
        persist()
    }

    private func purgeExpired(at date: Date) {
        let originalCount = state.pending.count
        state.pending.removeAll { date.timeIntervalSince($0.recordedAt) >= Self.pendingLifetime }
        if state.pending.count != originalCount {
            generation += 1
            persist()
        }
    }

    private func persist() {
        _ = persist(state)
    }

    @discardableResult
    private func persist(_ updated: State) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            ErrorLogStore.shared.log("Global soul memory save failed: \(error.localizedDescription)")
            return false
        }
    }
}
