import Foundation
import Testing
@testable import Typeflux

/// Commits once, then withholds the reply to model an ambiguous execution outcome.
private final class DelayedWordBookReply: AskWordBookStoring, @unchecked Sendable {
    let store: SQLiteAskWordBookStore
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var committed = false
    var didCommit: Bool { lock.withLock { committed } }
    init(_ store: SQLiteAskWordBookStore) { self.store = store }
    func record(_ lookup: AskWordBookLookup, at date: Date, counts: Bool) throws -> AskWordBookEntry? {
        let result = try store.record(lookup, at: date, counts: counts)
        lock.withLock { committed = true }
        _ = gate.wait(timeout: .now() + 5)
        return result
    }
    func entry(forKey key: String) throws -> AskWordBookEntry? { try store.entry(forKey: key) }
    func setStarred(_ starred: Bool, lookup: AskWordBookLookup, at date: Date) throws -> AskWordBookEntry? {
        try store.setStarred(starred, lookup: lookup, at: date)
    }
    func list(_ query: AskWordBookQuery) throws -> [AskWordBookEntry] { try store.list(query) }
    func count(_ scope: AskWordBookQuery.Scope) throws -> Int { try store.count(scope) }
    func count(matching query: AskWordBookQuery) throws -> Int { try store.count(matching: query) }
    func activity(since date: Date) throws -> [Date] { try store.activity(since: date) }
    func lookups(since date: Date) throws -> Int { try store.lookups(since: date) }
    func languagePairs() throws -> [AskWordBookLanguagePair] { try store.languagePairs() }
    func delete(keys: [String]) throws { try store.delete(keys: keys) }
    func restore(_ entries: [AskWordBookEntry]) throws { try store.restore(entries) }
    func purgeHistory(before date: Date?) throws { try store.purgeHistory(before: date) }
}

@Suite("Word book unknown execution outcomes", .exclusiveUIState)
@MainActor
struct WordBookUnknownOutcomeTests {
    @Test func timedOutCommittedWriteIsNeverReplayedAndReplacementWaitsForItsReturn() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let raw = SQLiteAskWordBookStore(url: fixture.url)
        raw.notificationCenter = NotificationCenter()
        let delayed = DelayedWordBookReply(raw)
        let clock = WordBookRecoveryClock()
        var policy = ModulePolicy(); policy.operationTimeout = 0.2; policy.automaticallyRecover = false
        let store = RecoveringAskWordBookStore(factory: {
            clock.open()
            return clock.opens == 1 ? delayed : SQLiteAskWordBookStore(url: fixture.url)
        }, policy: policy, uptime: { clock.now() })
        await #expect(throws: LocalStoreFailure.unavailable) {
            try await store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true)
        }
        #expect(delayed.didCommit)
        clock.advance()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.count(.all) }
        #expect(clock.opens == 1)
        delayed.gate.signal()
        for _ in 0..<400 {
            let health = await store.module.supervisor.health()
            if !health.hasLifecycleWork && health.activeOperations == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await store.entry(forKey: fixture.lookup.key)?.lookupCount == 1)
        #expect(clock.opens == 2)
        await store.shutdown()
    }

    @Test func recorderRejectsConcurrentMutationsAndDoesNotCarrySessionClaimsAcrossAnAwait() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let raw = SQLiteAskWordBookStore(url: fixture.url)
        raw.notificationCenter = NotificationCenter()
        let delayed = DelayedWordBookReply(raw)
        let store = RecoveringAskWordBookStore(factory: { delayed })
        let recorder = AskWordBookRecorder(store: store)
        let first = Task { try await recorder.record(fixture.lookup) }
        for _ in 0..<400 where !delayed.didCommit { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delayed.didCommit)
        await #expect(throws: LocalStoreFailure.busy) { try await recorder.record(fixture.lookup) }
        await #expect(throws: LocalStoreFailure.busy) { try await recorder.toggleStar(fixture.lookup) }
        recorder.beginSession()
        delayed.gate.signal()
        try await first.value
        delayed.gate.signal()
        try await recorder.record(fixture.lookup)
        #expect(try raw.entry(forKey: fixture.lookup.key)?.lookupCount == 2)
        await store.shutdown()
    }
}
