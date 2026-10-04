import Foundation

struct RecentInputMemory: Codable, Identifiable, Equatable {
    let id: UUID
    let appIdentifier: String
    let scope: String
    let text: String
    let recordedAt: Date
    var provenance: MemoryProvenance?
}

/// Device-local excerpts are also partitioned by account. Unattributed legacy
/// entries belong only to the signed-out local identity, never the next login.
final class RecentInputMemoryStore: @unchecked Sendable {
    static let shared: RecentInputMemoryStore = {
        let store = RecentInputMemoryStore(
            soulStore: .shared,
            onChange: { MemoryInvalidationStore.shared.invalidate(owner: $0) }
        )
        store.recoverInvalidations(using: .shared)
        return store
    }()

    static let lifetime: TimeInterval = 24 * 60 * 60
    static let maximumPerApp = 20
    static let maximumExcerptLength = 700

    private struct State: Codable {
        var items: [RecentInputMemory] = []
        var tombstones: Set<UUID> = []
        var generation = 0
        var invalidatedOwners: [String: Date]?
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let soulStore: GlobalSoulMemoryStore?
    private let storage: any AskMemoryNoteFileStorage
    private let onChange: @Sendable (String) -> Void
    private var state: State

    init(
        fileURL: URL? = nil,
        soulStore: GlobalSoulMemoryStore? = nil,
        storage: any AskMemoryNoteFileStorage = LocalAskMemoryNoteFileStorage(),
        onChange: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux", isDirectory: true)
        self.fileURL = fileURL ?? base.appendingPathComponent("recent-input-memory.json")
        self.storage = storage
        self.soulStore = soulStore
        self.onChange = onChange
        let data = try? storage.read(from: self.fileURL)
        state = data.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State(items: data.flatMap { try? JSONDecoder().decode([RecentInputMemory].self, from: $0) } ?? [])
        for index in state.items.indices where state.items[index].provenance == nil {
            let item = state.items[index]
            state.items[index].provenance = .init(id: item.id.uuidString, source: .recent, owner: "local",
                                                  scope: "device/" + item.scope, createdAt: item.recordedAt,
                                                  updatedAt: item.recordedAt,
                                                  expiry: item.recordedAt.addingTimeInterval(Self.lifetime))
        }
    }

    func recoverInvalidations(using invalidations: MemoryInvalidationStore) {
        lock.lock(); defer { lock.unlock() }
        for (owner, date) in state.invalidatedOwners ?? [:]
            where date > (invalidations.cutoff(owner: owner) ?? .distantPast) {
            invalidations.invalidate(owner: owner, at: date, notify: false)
        }
    }

    func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.generation
    }

    /// Authentication transitions invalidate every in-flight AX observation, even
    /// if the user returns to the same account before its next callback.
    func invalidateObservations() {
        lock.lock(); defer { lock.unlock() }
        state.generation += 1
    }

    @discardableResult
    func upsert(id: UUID, appIdentifier: String, scope: String, text: String,
                at date: Date = Date(), expectedGeneration: Int? = nil, owner: String = "local") -> Bool {
        let excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumExcerptLength))
        guard !excerpt.isEmpty, !owner.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !state.tombstones.contains(id),
              expectedGeneration.map({ $0 == state.generation }) ?? true else { return false }
        let previous = state.items.first { $0.id == id }
        guard previous?.provenance?.owner == nil || previous?.provenance?.owner == owner else { return false }
        var next = state
        next.items.removeAll { $0.id == id || !active($0, at: date) }
        next.items.append(.init(id: id, appIdentifier: appIdentifier, scope: scope, text: excerpt, recordedAt: date,
                                provenance: .init(
                                    id: id.uuidString,
                                    source: .recent,
                                    owner: owner,
                                    scope: "device/" + scope,
                                    version: (previous?.provenance?.version ?? 0) + 1,
                                    createdAt: previous?.provenance?.createdAt ?? date,
                                    updatedAt: date,
                                    expiry: date.addingTimeInterval(Self.lifetime)
                                )))
        let appItems = next.items.filter { $0.appIdentifier == appIdentifier && $0.provenance?.owner == owner }
            .sorted { $0.recordedAt > $1.recordedAt }
        let surplus = Set(appItems.dropFirst(Self.maximumPerApp).map(\.id))
        next.items.removeAll { surplus.contains($0.id) }
        return commit(next)
    }

    func recent(scope: String, limit: Int = 4, at date: Date = Date(), owner: String = "local") -> [String] {
        Array(list(at: date, owner: owner).filter { $0.scope == scope }.prefix(max(0, limit)).map(\.text))
    }

    func appIdentifiers(at date: Date = Date(), owner: String = "local") -> [String] {
        Array(Set(list(at: date, owner: owner).map(\.appIdentifier))).sorted()
    }

    func list(at date: Date = Date(), owner: String = "local", query: String = "") -> [RecentInputMemory] {
        lock.lock(); defer { lock.unlock() }
        return state.items.filter {
            $0.provenance?.owner == owner && active($0, at: date)
                && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }.sorted { $0.recordedAt > $1.recordedAt }
    }

    @discardableResult
    func delete(id: UUID, owner: String = "local") -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.items.contains(where: { $0.id == id && $0.provenance?.owner == owner }) else { return false }
        var next = state
        next.invalidatedOwners = next.invalidatedOwners ?? [:]
        next.invalidatedOwners?[owner] = Date()
        next.generation += 1
        next.tombstones.insert(id)
        next.items.removeAll { $0.id == id }
        guard soulStore?.removeInput(id: id) ?? true, commit(next) else { return false }
        onChange(owner)
        return true
    }

    @discardableResult
    func clear(appIdentifier: String? = nil, owner: String = "local") -> Bool {
        lock.lock(); defer { lock.unlock() }
        var next = state
        let ids = Set(next.items
            .filter { $0.provenance?.owner == owner && (appIdentifier == nil || $0.appIdentifier == appIdentifier) }
            .map(\.id))
        next.invalidatedOwners = next.invalidatedOwners ?? [:]
        next.invalidatedOwners?[owner] = Date()
        next.generation += 1
        next.tombstones.formUnion(ids)
        next.items.removeAll { ids.contains($0.id) }
        guard soulStore?.clearPending(appIdentifier: appIdentifier, ownerID: owner) ?? true,
              commit(next) else { return false }
        onChange(owner)
        return true
    }

    private func active(_ item: RecentInputMemory, at date: Date) -> Bool {
        date < (item.provenance?.expiry ?? item.recordedAt.addingTimeInterval(Self.lifetime))
    }

    private func commit(_ next: State) -> Bool {
        do {
            try storage.writeAtomically(JSONEncoder().encode(next), to: fileURL)
            state = next
            return true
        } catch {
            ErrorLogStore.shared.log("Recent input memory save failed: \(error.localizedDescription)")
            return false
        }
    }
}
