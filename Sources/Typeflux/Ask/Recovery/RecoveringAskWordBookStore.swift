import Foundation

/// A stable store shared by the launcher, translation panel and word-book window.
/// Reopening is supervised; the failed operation is never replayed.
final class RecoveringAskWordBookStore: AskWordBookStoring {
    let module: ModuleHandle<any AskWordBookStoring>

    init(factory: @escaping @Sendable () throws -> any AskWordBookStoring = {
        SQLiteAskWordBookStore(url: SQLiteAskWordBookStore.defaultURL())
    }, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        module = ModuleHandle(policy: policy, factory: {
            let store = try factory()
            _ = try await store.count(.all)
            return store
        }, classify: { error in
            (error as? LocalStoreFailure) == .invalidData ? .waitForExplicitRetry : .recover
        }, uptime: uptime)
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (any AskWordBookStoring) async throws -> T
    ) async throws -> T {
        do { return try await module.perform(operation) } catch is ModuleFailure {
            throw LocalStoreFailure.unavailable
        }
    }

    func entry(forKey key: String) async throws -> AskWordBookEntry? {
        try await perform { try await $0.entry(forKey: key) }
    }
    func record(_ lookup: AskWordBookLookup, at date: Date, counts: Bool) async throws -> AskWordBookEntry? {
        try await perform { try await $0.record(lookup, at: date, counts: counts) }
    }
    func setStarred(_ starred: Bool, lookup: AskWordBookLookup, at date: Date) async throws -> AskWordBookEntry? {
        try await perform { try await $0.setStarred(starred, lookup: lookup, at: date) }
    }
    func list(_ query: AskWordBookQuery) async throws -> [AskWordBookEntry] {
        try await perform { try await $0.list(query) }
    }
    func count(_ scope: AskWordBookQuery.Scope) async throws -> Int {
        try await perform { try await $0.count(scope) }
    }
    func count(matching query: AskWordBookQuery) async throws -> Int {
        try await perform { try await $0.count(matching: query) }
    }
    func activity(since date: Date) async throws -> [Date] {
        try await perform { try await $0.activity(since: date) }
    }
    func lookups(since date: Date) async throws -> Int {
        try await perform { try await $0.lookups(since: date) }
    }
    func languagePairs() async throws -> [AskWordBookLanguagePair] {
        try await perform { try await $0.languagePairs() }
    }
    func delete(keys: [String]) async throws { try await perform { try await $0.delete(keys: keys) } }
    func restore(_ entries: [AskWordBookEntry]) async throws { try await perform { try await $0.restore(entries) } }
    func purgeHistory(before date: Date?) async throws { try await perform { try await $0.purgeHistory(before: date) } }

    func preventNewWork() { module.preventNewWork() }
    func shutdown() async { await module.shutdown() }
}
