import Foundation
import Testing
@testable import Typeflux

private final class HealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
}

@Suite("Persistent module recovery reservations")
struct ModuleHealthStoreTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("health-" + UUID().uuidString)
    }

    @Test func attemptsSurviveRestartAndQuarantineRequiresExplicitReset() throws {
        let root = location(), url = root.appendingPathComponent("notebook.json")
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<4 { try ModuleHealthStore(url: url).reserve() }
        let store = ModuleHealthStore(url: url)
        #expect(throws: ModuleFailure.quarantined) { try store.reserve() }
        store.cleanStop()
        #expect(throws: ModuleFailure.quarantined) { try ModuleHealthStore(url: url).reserve() }
        try store.reset()
        try store.reserve()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["version", "attempts", "quarantined"])
        #expect(object?["attempts"] as? Int == 1)
    }

    @Test func automaticRecoveryGetsOneMoreBudgetAndStopsAfterRepeatedFailure() throws {
        let root = location(), url = root.appendingPathComponent("notebook.json")
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<4 { try ModuleHealthStore(url: url).reserve() }

        let recovery = ModuleHealthStore(url: url)
        try recovery.reserve(automaticRecovery: true)
        var record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: url))
        #expect(record.attempts == 1)
        #expect(record.automaticRecoveryUsed == true)

        for _ in 0..<3 { try ModuleHealthStore(url: url).reserve(automaticRecovery: true) }
        #expect(throws: ModuleFailure.quarantined) {
            try ModuleHealthStore(url: url).reserve(automaticRecovery: true)
        }
        record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: url))
        #expect(record.attempts == 4)
        #expect(record.automaticRecoveryUsed == true)

        let cleanURL = root.appendingPathComponent("wordBook.json")
        for _ in 0..<4 { try ModuleHealthStore(url: cleanURL).reserve() }
        let healthy = ModuleHealthStore(url: cleanURL)
        try healthy.reserve(automaticRecovery: true)
        healthy.succeeded()
        healthy.cleanStop()
        record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: cleanURL))
        #expect(record.attempts == 0)
        #expect(record.automaticRecoveryUsed == nil)
    }

    @Test func cleanStopAndObservedStabilityRestoreBudgetButFailureDoesNot() throws {
        let root = location(), clock = HealthClock()
        let url = root.appendingPathComponent("wordBook.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleHealthStore(url: url, uptime: { clock.now() })
        try store.reserve()
        store.succeeded()
        store.failed()
        store.cleanStop()
        try store.reserve()
        store.succeeded()
        clock.advance()
        store.succeeded()
        try store.reserve()
        var record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: url))
        #expect(record.attempts == 1)
        store.succeeded()
        store.cleanStop()
        record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: url))
        #expect(record.attempts == 0)
        #expect(ModuleHealthStore.directory().lastPathComponent == "ModuleHealth")
    }

    @Test func corruptOversizedUnknownVersionAndNonregularFilesFailClosed() throws {
        let root = location(), url = root.appendingPathComponent("conversations.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtures = [Data(), Data("broken".utf8), Data(repeating: 65, count: 4097),
                        Data(#"{"version":2,"attempts":0,"quarantined":false}"#.utf8),
                        Data(#"{"version":1,"attempts":-1,"quarantined":false}"#.utf8),
                        Data(#"{"version":1,"attempts":4,"quarantined":false}"#.utf8)]
        for data in fixtures {
            try data.write(to: url)
            let store = ModuleHealthStore(url: url)
            #expect(throws: ModuleFailure.healthPersistence) { try store.reserve() }
            #expect(try Data(contentsOf: url) == data, "Automatic recovery must retain damaged metadata")
            #expect(throws: ModuleFailure.healthPersistence) { try store.reserve(automaticRecovery: true) }
            try store.reset()
            try store.reserve()
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: ModuleFailure.healthPersistence) { try ModuleHealthStore(url: url).reserve() }
    }

    @Test func failedWritesPreventFactoryAdmissionAndDoNotAffectAnotherModule() throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("occupied".utf8).write(to: root)
        let store = ModuleHealthStore(url: root.appendingPathComponent("notebook.json"))
        #expect(throws: ModuleFailure.healthPersistence) { try store.reserve() }
        #expect(throws: ModuleFailure.healthPersistence) { try store.reset() }
        try FileManager.default.removeItem(at: root)
        try store.reset()
        try store.reserve()
        store.succeeded()
        // Replacing the metadata destination with a directory simulates a
        // cleanup write failure without depending on the test user's uid.
        let url = root.appendingPathComponent("notebook.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.cleanStop()
        #expect(throws: ModuleFailure.healthPersistence) { try store.reserve() }
        try ModuleHealthStore(url: root.appendingPathComponent("wordBook.json")).reserve()
    }

    @Test func supervisorPersistsFailureWithoutReplayingOperations() async throws {
        let root = location(), url = root.appendingPathComponent("notebook.json")
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        for _ in 0..<4 {
            let handle = ModuleHandle(policy: policy, healthStore: ModuleHealthStore(url: url), factory: { 7 })
            await #expect(throws: ModuleFailure.unavailable) {
                try await handle.perform { _ in throw ModuleFailure.unavailable }
            }
            await handle.shutdown()
            await handle.supervisor.waitForRetirement()
        }
        let quarantined = ModuleHandle(policy: policy, healthStore: ModuleHealthStore(url: url), factory: {
            Issue.record("A quarantined module entered its factory"); return 1
        })
        await #expect(throws: ModuleFailure.quarantined) { try await quarantined.start() }
        #expect(await quarantined.supervisor.health().failure == .quarantined)
        await quarantined.shutdown()

        try Data("broken".utf8).write(to: url)
        let corrupt = ModuleHandle(healthStore: ModuleHealthStore(url: url), factory: {
            Issue.record("Corrupt health metadata entered its factory"); return 1
        })
        await #expect(throws: ModuleFailure.healthPersistence) { try await corrupt.start() }
        #expect(await corrupt.supervisor.health().state == .degraded)
        await corrupt.shutdown()
    }

    @Test func explicitResetIsBoundedAndNeverResetsAHealthyModule() async throws {
        let root = location(), url = root.appendingPathComponent("notebook.json"), clock = HealthClock()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<4 { try ModuleHealthStore(url: url).reserve() }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let handle = ModuleHandle(policy: policy, healthStore: ModuleHealthStore(url: url), factory: { 7 },
                                  uptime: { clock.now() })
        await #expect(throws: ModuleFailure.quarantined) { try await handle.start() }
        clock.advance()
        await handle.retry(resetPersistentBudget: true)
        #expect(try await handle.perform { $0 } == 7)
        await handle.retry(resetPersistentBudget: true)
        let record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: url))
        #expect(record.attempts == 1)
        await handle.shutdown()
        await handle.supervisor.waitForRetirement()
    }
}

@Suite("Storage module registry wiring", .exclusiveUIState)
@MainActor
struct StorageModuleRegistryTests {
    @Test func quarantinedLegacyStorageStartsWithoutUserAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = Data(#"{"version":1,"attempts":4,"quarantined":true}"#.utf8)
        for file in ["notebook.json", "wordBook.json", "conversations.json"] {
            try legacy.write(to: root.appendingPathComponent(file))
        }

        let storage = StorageModules(healthDirectory: root,
            conversationFactory: { try AskConversationCache(url: root.appendingPathComponent("cache.db")) },
            wordBookFactory: { SQLiteAskWordBookStore(url: root.appendingPathComponent("words.db")) },
            noteFactory: { SQLiteAskNoteStore(url: root.appendingPathComponent("notes.db")) })
        #expect(await storage.registry.startAll().isEmpty)
        #expect(try await storage.notes.count(.all) == 0)
        #expect(try await storage.words.count(.all) == 0)
        #expect(try await storage.conversations.list(owner: "test").isEmpty)

        for file in ["notebook.json", "wordBook.json", "conversations.json"] {
            let record = try JSONDecoder().decode(ModuleHealthStore.Record.self,
                from: Data(contentsOf: root.appendingPathComponent(file)))
            #expect(record.attempts == 1)
            #expect(record.automaticRecoveryUsed == true)
        }
        await storage.registry.shutdown()
    }

    @Test func threeFacadesUseIndependentFactoriesAndPersistentLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageModules(healthDirectory: root,
            conversationFactory: { try AskConversationCache(url: root.appendingPathComponent("cache.db")) },
            wordBookFactory: { SQLiteAskWordBookStore(url: root.appendingPathComponent("words.db")) },
            noteFactory: { SQLiteAskNoteStore(url: root.appendingPathComponent("notes.db")) })
        let notes = storage.notes, words = storage.words, cache = storage.conversations
        let registry = storage.registry
        #expect(await registry.startAll().isEmpty)
        #expect(try await notes.count(.all) == 0)
        #expect(try await words.count(.all) == 0)
        #expect(try await cache.list(owner: "test").isEmpty)
        await registry.disable(.notebook)
        await #expect(throws: LocalStoreFailure.unavailable) { try await notes.count(.all) }
        #expect(try await words.count(.all) == 0)
        try await registry.start(.notebook)
        await registry.shutdown()
        for file in ["notebook.json", "wordBook.json", "conversations.json"] {
            let record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent(file)))
            #expect(record.attempts == 0)
        }
    }
}
