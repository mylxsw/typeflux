import Foundation
import SQLite3
import Testing
@testable import Typeflux

/// Real SQLite failures exercise transaction boundaries as well as supervisor recovery.
struct WordBookFaultFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { root.appendingPathComponent("words.sqlite") }
    let lookup = AskWordBookLookup(headword: "word", source: "en", target: "zh-Hans", translation: "meaning")
    func sql(_ sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

final class WordBookRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var attempts = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 301 } }
    func open() { lock.withLock { attempts += 1 } }
    var opens: Int { lock.withLock { attempts } }
}

@Suite("Supervised word book storage")
struct RecoveringAskWordBookStoreTests {
    private func policy() -> ModulePolicy {
        var policy = ModulePolicy()
        policy.automaticallyRecover = false
        return policy
    }
    private func settle(_ store: RecoveringAskWordBookStore) async throws {
        for _ in 0..<400 {
            let health = await store.module.supervisor.health()
            if !health.hasLifecycleWork && health.activeOperations == 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Storage cleanup did not settle")
    }

    @Test func failedOpenIsExplicitAndReopensWithoutReplacingTheDatabase() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        try Data("occupied".utf8).write(to: fixture.root)
        let clock = WordBookRecoveryClock()
        let store = RecoveringAskWordBookStore(factory: {
            clock.open()
            return SQLiteAskWordBookStore(url: fixture.url)
        }, policy: policy(), uptime: { clock.now() })
        #expect(clock.opens == 0)
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.list(.init()) }
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true) }
        #expect(clock.opens == 1)
        try FileManager.default.removeItem(at: fixture.root)
        clock.advance()
        #expect(try await store.count(.all) == 0)
        #expect(clock.opens == 2)
        _ = try await store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true)
        await store.module.setEnabled(false)
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.count(.all) }
        try await settle(store)
        await store.module.setEnabled(true)
        #expect(try await store.entry(forKey: fixture.lookup.key)?.lookupCount == 1)
        store.preventNewWork()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.count(.all) }
        await store.shutdown()
    }

    @Test func failedMutationIsNotReplayedWhenTheConnectionRecovers() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let clock = WordBookRecoveryClock()
        let store = RecoveringAskWordBookStore(factory: {
            clock.open()
            return SQLiteAskWordBookStore(url: fixture.url)
        }, policy: policy(), uptime: { clock.now() })
        let first = try #require(try await store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true))
        try fixture.sql("CREATE TRIGGER fail_update BEFORE UPDATE ON word_book_entries BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true) }
        try await settle(store)
        try fixture.sql("DROP TRIGGER fail_update;")
        clock.advance()
        #expect(try await store.entry(forKey: fixture.lookup.key) == first)
        #expect(clock.opens == 2)
        #expect(try await store.setStarred(true, lookup: fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000))?.isStarred == true)
        #expect(try await store.count(.starred) == 1)
        #expect(try await store.count(matching: .init(text: "word")) == 1)
        #expect(try await store.list(.init()).count == 1)
        #expect(try await store.activity(since: .distantPast).count == 2)
        #expect(try await store.lookups(since: .distantPast) == 1)
        #expect(try await store.languagePairs().count == 1)
        try await store.delete(keys: [first.key])
        try await store.restore([first])
        try await store.purgeHistory(before: nil)
        #expect(try await store.count(.all) == 0)
        await store.shutdown()
    }

    @Test func blockedFactoryTimesOutWithoutStartingAnotherConnection() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let gate = DispatchSemaphore(value: 0)
        let clock = WordBookRecoveryClock()
        var policy = policy(); policy.startupTimeout = 0.03
        let store = RecoveringAskWordBookStore(factory: {
            clock.open()
            _ = gate.wait(timeout: .now() + 3)
            return SQLiteAskWordBookStore(url: fixture.url)
        }, policy: policy, uptime: { clock.now() })
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.count(.all) }
        clock.advance()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.count(.all) }
        #expect(clock.opens == 1)
        gate.signal()
        await store.shutdown()
        try await settle(store)
    }

    @Test func invalidDataWaitsForExplicitRecovery() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let clock = WordBookRecoveryClock()
        let store = RecoveringAskWordBookStore(factory: {
            clock.open()
            return SQLiteAskWordBookStore(url: fixture.url)
        }, policy: policy(), uptime: { clock.now() })
        _ = try await store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true)
        try fixture.sql("UPDATE word_book_entries SET card_json = x'01';")
        await #expect(throws: LocalStoreFailure.invalidData) { try await store.list(.init()) }
        try await settle(store)
        clock.advance()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.list(.init()) }
        #expect(clock.opens == 1)
        try fixture.sql("UPDATE word_book_entries SET card_json = NULL;")
        await store.module.setEnabled(false)
        await store.module.setEnabled(true)
        #expect(try await store.list(.init()).count == 1)
        await store.shutdown()
    }
}

@Suite("Word book SQLite failure atomicity", .exclusiveUIState)
@MainActor
struct WordBookStorageFailureTests {
    @Test func lockedWritesDoNotNotifyOrChangeCounts() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let store = SQLiteAskWordBookStore(url: fixture.url)
        let first = try #require(try store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true))
        // Drain the successful write notification before counting failed writes.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let counter = AskWordBookStoreTests.Counter()
        let center = NotificationCenter()
        store.notificationCenter = center
        let token = center.addObserver(forName: .askWordBookDidChange, object: nil, queue: .main) { _ in counter.add() }
        defer { center.removeObserver(token) }
        var db: OpaquePointer?
        try #require(sqlite3_open(fixture.url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
        #expect(throws: LocalStoreFailure.unavailable) { try store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true) }
        #expect(throws: LocalStoreFailure.unavailable) { try store.setStarred(true, lookup: fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000)) }
        try #require(sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(counter.value == 0)
        #expect(try store.entry(forKey: first.key) == first)
    }

    @Test func partialDeleteAndRestoreRollBackAndOverflowCannotTrap() throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let store = SQLiteAskWordBookStore(url: fixture.url)
        store.notificationCenter = NotificationCenter()
        let first = try #require(try store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true))
        var other = fixture.lookup; other.headword = "other"
        let second = try #require(try store.record(other, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true))
        try fixture.sql("CREATE TRIGGER fail_delete BEFORE DELETE ON word_book_entries WHEN OLD.headword = 'other' BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        #expect(throws: LocalStoreFailure.unavailable) { try store.delete(keys: [first.key, second.key]) }
        #expect(try store.count(.all) == 2)
        try fixture.sql("DROP TRIGGER fail_delete;")
        try store.delete(keys: [first.key, second.key])
        try fixture.sql("CREATE TRIGGER fail_restore BEFORE INSERT ON word_book_entries WHEN NEW.headword = 'other' BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        #expect(throws: LocalStoreFailure.unavailable) { try store.restore([first, second]) }
        #expect(try store.count(.all) == 0)
        try fixture.sql("DROP TRIGGER fail_restore;")
        try store.restore([first])
        try fixture.sql("UPDATE word_book_entries SET lookup_count = 9223372036854775807;")
        #expect(throws: LocalStoreFailure.invalidData) { try store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true) }
        #expect(try store.entry(forKey: first.key)?.lookupCount == Int.max)
        try fixture.sql("UPDATE word_book_entries SET id = 'invalid';")
        #expect(throws: LocalStoreFailure.invalidData) { try store.list(.init()) }
    }

    @Test func recorderCountsOnlyConfirmedPersistenceAndNeverClaimsFailedStar() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let store = SQLiteAskWordBookStore(url: fixture.url)
        store.notificationCenter = NotificationCenter()
        let recorder = AskWordBookRecorder(store: store)
        try fixture.sql("CREATE TRIGGER fail_record BEFORE INSERT ON word_book_entries BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        await #expect(throws: LocalStoreFailure.unavailable) { try await recorder.record(fixture.lookup) }
        await #expect(throws: LocalStoreFailure.unavailable) { try await recorder.toggleStar(fixture.lookup) }
        #expect(try store.count(.all) == 0)
        try fixture.sql("DROP TRIGGER fail_record;")
        try await recorder.record(fixture.lookup)
        try await recorder.record(fixture.lookup)
        #expect(try store.entry(forKey: fixture.lookup.key)?.lookupCount == 1)
        recorder.beginSession()
        try await recorder.record(fixture.lookup)
        #expect(try store.entry(forKey: fixture.lookup.key)?.lookupCount == 2)
    }

    @Test func failedReadsKeepSnapshotAndFailedWritesKeepResultsAndUndo() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let store = SQLiteAskWordBookStore(url: fixture.url)
        store.notificationCenter = NotificationCenter()
        let entry = try #require(try store.record(fixture.lookup, at: Date(timeIntervalSince1970: 1_800_000_000), counts: true))
        let suite = "wordbook-failures-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AskWordBookViewModel(store: store, settings: SettingsStore(defaults: defaults))
        await model.refresh()
        try fixture.sql("ALTER TABLE word_book_entries RENAME TO held_entries;")
        await model.refresh()
        #expect(model.entries == [entry] && model.counts[.all] == 1)
        #expect(model.notice == L("ask.wordBook.storageUnavailable"))
        await model.toggleStar(entry)
        #expect(model.entries == [entry] && model.notice == L("ask.wordBook.saveFailed"))
        await model.delete(entry)
        #expect(model.deleted.isEmpty && model.entries == [entry])
        await model.clearHistory()
        #expect(model.entries == [entry] && model.notice == L("ask.wordBook.saveFailed"))
        var exported = false
        model.chooseExportURL = { _ in exported = true; return nil }
        await model.export(.csv)
        #expect(!exported && model.notice == L("ask.wordBook.storageUnavailable"))
        model.dictionary = AskTestWordLookup(answer: .card(wordBookCard))
        model.detector = AskTestLanguageDetector(language: "en")
        model.interfaceLanguage = { .simplifiedChinese }
        await model.lookUp("serendipity")
        #expect(model.transient?.lookup.card == wordBookCard && model.notice == L("ask.wordBook.saveFailed"))
        await model.regenerate(entry)
        #expect(model.transient?.lookup.card == wordBookCard && model.notice == L("ask.wordBook.saveFailed"))
        try fixture.sql("ALTER TABLE held_entries RENAME TO word_book_entries;")
        await model.refresh()
        #expect(try store.entry(forKey: entry.key) == entry, "Recovery must not replay either write")
        await model.delete(entry)
        #expect(model.deleted == [entry])
        try fixture.sql("CREATE TRIGGER fail_restore BEFORE INSERT ON word_book_entries BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        await model.undoDelete()
        #expect(model.deleted == [entry] && model.notice == L("ask.wordBook.saveFailed"))
        try fixture.sql("DROP TRIGGER fail_restore;")
        await model.undoDelete()
        #expect(model.deleted.isEmpty && model.entries == [entry])
    }
}
