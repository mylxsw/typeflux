import Foundation

enum ModuleRegistryFailure: Error, Equatable {
    case duplicate, unknownDependency, cycle, unknownModule, disabled, invalidated, observationUnavailable
}

/// Type erasure applies only to lifecycle control. Feature operations continue
/// through their independent typed handles, never through a registry executor.
struct ModuleRegistration: Sendable {
    let id: ModuleID
    let dependencies: [ModuleID]
    let health: ModuleHealthChannel
    let admission: ModuleAdmission
    let start: @Sendable () async throws -> Void
    let stop: @Sendable (Bool) async -> Bool

    init<Service>(_ id: ModuleID, handle: ModuleHandle<Service>, dependencies: [ModuleID] = []) {
        self.id = id
        self.dependencies = dependencies
        health = handle.health
        admission = handle.supervisor.admission
        start = { try await handle.supervisor.startManaged() }
        stop = { permanent in
            if permanent { await handle.shutdown() } else { await handle.setEnabled(false) }
            return await handle.supervisor.waitForRetirement()
        }
    }
}

/// Immutable, bounded graph with one owned startup and observation task per node.
/// Invalid graphs fail closed without preventing the app shell from starting.
actor ModuleRegistry {
    nonisolated let registrations: [ModuleRegistration]
    private let order: [ModuleID]
    private let validationFailure: ModuleRegistryFailure?
    private var pending: [ModuleID: (UUID, Task<Void, any Error>)] = [:]
    private var observations: [ModuleID: Task<Void, Never>] = [:]
    private var revisions: [ModuleID: UUID] = [:]
    private var terminated = false
    private var stopping: Set<ModuleID> = []
    private var active: Set<ModuleID> = []
    private var requestedStops: Set<ModuleID> = []
    private var retirement: Task<Void, Never>?

    init(_ registrations: [ModuleRegistration]) {
        self.registrations = registrations
        let result = Self.validate(registrations)
        order = result.0
        validationFailure = result.1
        for entry in registrations {
            entry.admission.setEnabled(false)
            entry.admission.require(registrations.filter { Self.ancestors(of: entry.id, in: registrations).contains($0.id) }.map(\.health))
        }
    }

    nonisolated func preventNewWork() {
        for entry in registrations { entry.admission.shutdown() }
    }

    func startAll() async -> [ModuleID: ModuleRegistryFailure] {
        var failures: [ModuleID: ModuleRegistryFailure] = [:]
        var tokens: [ModuleID: UUID] = [:]
        for entry in registrations { tokens[entry.id] = revision(entry.id) }
        for entry in registrations {
            guard tokens[entry.id] == revision(entry.id) else {
                failures[entry.id] = .invalidated; continue
            }
            do { try await start(entry.id) }
            catch { failures[entry.id] = (error as? ModuleRegistryFailure) ?? .disabled }
        }
        return failures
    }

    func start(_ id: ModuleID) async throws {
        try Task.checkCancellation()
        if let validationFailure { throw validationFailure }
        guard !terminated else { throw ModuleRegistryFailure.disabled }
        guard registrations.contains(where: { $0.id == id }) else { throw ModuleRegistryFailure.unknownModule }
        try observeDependencies()
        let required = ancestors(of: id).union([id])
        guard required.isDisjoint(with: stopping) else { throw ModuleRegistryFailure.disabled }
        // Capture all revisions before awaiting a dependency: disabling the
        // target while its dependency opens must not resurrect the target.
        let tokens = Dictionary(uniqueKeysWithValues: required.map { ($0, revision($0)) })
        for node in order where required.contains(node) {
            try Task.checkCancellation()
            guard !terminated, required.allSatisfy({ tokens[$0] == revision($0) }) else {
                throw ModuleRegistryFailure.invalidated
            }
            guard let entry = registrations.first(where: { $0.id == node }) else { continue }
            let owned: (UUID, Task<Void, any Error>)
            if let existing = pending[node] { owned = existing }
            else {
                entry.admission.setEnabled(true)
                active.insert(node)
                owned = (UUID(), Task { try await entry.start() })
                pending[node] = owned
            }
            do { try await owned.1.value }
            catch {
                if pending[node]?.0 == owned.0 { pending[node] = nil }
                throw error
            }
            if pending[node]?.0 == owned.0 { pending[node] = nil }
            guard !terminated, tokens[node] == revision(node) else { throw ModuleRegistryFailure.invalidated }
        }
        try Task.checkCancellation()
    }

    func disable(_ id: ModuleID) async {
        await stop(descendants(of: id).union([id]))
    }

    func shutdown() async {
        preventNewWork()
        terminated = true
        for task in observations.values { task.cancel() }
        observations.removeAll()
        await stop(Set(registrations.map(\.id)))
    }

    private func stop(_ ids: Set<ModuleID>) async {
        // Fence the whole affected subgraph before the first suspension. One
        // coalesced retirement task owns cleanup even when disable and quit race.
        stopping.formUnion(ids)
        requestedStops.formUnion(ids)
        for entry in registrations where ids.contains(entry.id) {
            active.remove(entry.id)
            revisions[entry.id] = UUID()
            entry.admission.setEnabled(false)
            pending.removeValue(forKey: entry.id)?.1.cancel()
        }
        if retirement == nil { retirement = Task { await self.drainStops() } }
        if let retirement { await retirement.value }
    }

    private func drainStops() async {
        let sorted = order.isEmpty ? registrations.map(\.id) : order
        while !requestedStops.isEmpty {
            let ids = requestedStops
            requestedStops.removeAll()
            var retained: Set<ModuleID> = []
            for id in sorted.reversed() where ids.contains(id) && !retained.contains(id) {
                if let entry = registrations.first(where: { $0.id == id }), !(await entry.stop(terminated)) {
                    // Uncooperative descendants may still reference dependencies.
                    // Keep those services owned and fenced until a later stop.
                    retained.formUnion(ancestors(of: id))
                }
            }
            stopping.subtract(ids.subtracting(requestedStops))
        }
        retirement = nil
    }

    private func revision(_ id: ModuleID) -> UUID {
        if let value = revisions[id] { return value }
        let value = UUID(); revisions[id] = value; return value
    }

    private func ancestors(of id: ModuleID) -> Set<ModuleID> {
        Self.ancestors(of: id, in: registrations)
    }

    private static func ancestors(of id: ModuleID, in registrations: [ModuleRegistration]) -> Set<ModuleID> {
        var found: Set<ModuleID> = []
        var remaining = registrations.first(where: { $0.id == id })?.dependencies ?? []
        while let next = remaining.popLast() {
            if found.insert(next).inserted {
                remaining += registrations.first(where: { $0.id == next })?.dependencies ?? []
            }
        }
        return found
    }

    private func descendants(of id: ModuleID) -> Set<ModuleID> {
        Set(registrations.filter { ancestors(of: $0.id).contains(id) }.map(\.id))
    }

    private func observeDependencies() throws {
        for entry in registrations where observations[entry.id] == nil && !descendants(of: entry.id).isEmpty {
            guard let stream = try? entry.health.observe() else { throw ModuleRegistryFailure.observationUnavailable }
            observations[entry.id] = Task { [weak self] in
                for await health in stream {
                    guard !Task.isCancelled else { return }
                    if health.state != .ready { await self?.dependencyFailed(entry.id) }
                }
            }
        }
    }

    private func dependencyFailed(_ id: ModuleID) async {
        guard !terminated, let entry = registrations.first(where: { $0.id == id }),
              entry.health.current?.state != .ready else { return }
        // Initial startup has no admitted dependents to invalidate.
        let affected = descendants(of: id).filter { child in
            active.contains(child)
        }
        if !affected.isEmpty { await stop(Set(affected)) }
    }

    private static func validate(_ entries: [ModuleRegistration]) -> ([ModuleID], ModuleRegistryFailure?) {
        let ids = Set(entries.map(\.id))
        guard ids.count == entries.count else { return ([], .duplicate) }
        guard entries.allSatisfy({ Set($0.dependencies).isSubset(of: ids) }) else { return ([], .unknownDependency) }
        var sorted: [ModuleID] = []
        var remaining = entries
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { Set($0.dependencies).isSubset(of: Set(sorted)) }) else {
                return ([], .cycle)
            }
            sorted.append(remaining.remove(at: index).id)
        }
        return (sorted, nil)
    }
}
