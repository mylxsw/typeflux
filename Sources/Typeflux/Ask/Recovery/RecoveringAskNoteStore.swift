import Foundation

/// A stable store shared by the launcher, agent and notebook window.
/// Reopening is supervised; the failed operation is never replayed.
final class RecoveringAskNoteStore: AskNoteStoring {
    let module: ModuleHandle<any AskNoteStoring>

    init(factory: @escaping @Sendable () throws -> any AskNoteStoring = {
        SQLiteAskNoteStore(url: SQLiteAskNoteStore.defaultURL())
    }, policy: ModulePolicy = .init(), healthStore: ModuleHealthStore? = nil,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        module = ModuleHandle(policy: policy, healthStore: healthStore, factory: {
            let store = try factory()
            _ = try await store.count(.all)
            return store
        }, classify: { error in
            (error as? LocalStoreFailure) == .invalidData ? .waitForExplicitRetry : .recover
        }, uptime: uptime)
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (any AskNoteStoring) async throws -> T
    ) async throws -> T {
        do { return try await module.perform(operation) } catch is ModuleFailure {
            throw LocalStoreFailure.unavailable
        }
    }

    func note(id: UUID) async throws -> AskNote? {
        try await perform { try await $0.note(id: id) }
    }
    @discardableResult
    func save(_ note: AskNote) async throws -> Bool {
        try await perform { try await $0.save(note) }
    }
    @discardableResult
    func save(_ note: AskNote, replacing previous: AskNote, revisionAt date: Date?) async throws -> Bool {
        try await perform { try await $0.save(note, replacing: previous, revisionAt: date) }
    }
    func delete(ids: [UUID]) async throws {
        try await perform { try await $0.delete(ids: ids) }
    }
    func restore(_ notes: [AskNote]) async throws {
        try await perform { try await $0.restore(notes) }
    }
    func list(_ query: AskNoteQuery) async throws -> [AskNote] {
        try await perform { try await $0.list(query) }
    }
    func count(_ scope: AskNoteQuery.Scope) async throws -> Int {
        try await perform { try await $0.count(scope) }
    }
    func commands() async throws -> [AskNoteFacet] {
        try await perform { try await $0.commands() }
    }
    func sources() async throws -> [AskNoteFacet] {
        try await perform { try await $0.sources() }
    }
    func tags() async throws -> [AskNoteFacet] {
        try await perform { try await $0.tags() }
    }
    func trash(ids: [UUID], at date: Date) async throws {
        try await perform { try await $0.trash(ids: ids, at: date) }
    }
    func purgeTrash(before date: Date) async throws {
        try await perform { try await $0.purgeTrash(before: date) }
    }
    func saveRevision(_ note: AskNote, at date: Date) async throws {
        try await perform { try await $0.saveRevision(note, at: date) }
    }
    func revisions(of id: UUID) async throws -> [AskNoteRevision] {
        try await perform { try await $0.revisions(of: id) }
    }
    func deleteRevision(of id: UUID, at date: Date) async throws {
        try await perform { try await $0.deleteRevision(of: id, at: date) }
    }

    func preventNewWork() { module.preventNewWork() }
    func shutdown() async { await module.shutdown() }
}
