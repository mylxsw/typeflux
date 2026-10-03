import Foundation
@testable import Typeflux
import XCTest

final class MemoryProvenanceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testCorrectionPersistsLineageConflictsAndExpiry() throws {
        let file = root.appendingPathComponent("notes.json")
        let store = AskMemoryNoteStore(fileURL: file)
        let now = Date()
        let first = try store.add("Uses imperial units", owner: "a")
        let next = try store.correct(id: first.id, text: "Uses metric units", owner: "a", expectedVersion: 1,
                                     expiry: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(next.provenance?.source, .correction)
        XCTAssertEqual(next.provenance?.supersedes, first.id)
        XCTAssertEqual(next.provenance?.version, 2)
        XCTAssertThrowsError(try store.correct(id: first.id, text: "stale", owner: "a", expectedVersion: 1))
        XCTAssertThrowsError(try store.correct(id: next.id, text: "wrong account", owner: "b", expectedVersion: 2))
        XCTAssertThrowsError(try store.correct(id: next.id, text: "wrong version", owner: "a", expectedVersion: 1))
        XCTAssertThrowsError(try store.correct(id: next.id, text: "", owner: "a", expectedVersion: 2))
        let reopened = AskMemoryNoteStore(fileURL: file)
        XCTAssertEqual(reopened.list(owner: "a", query: "METRIC", at: now), [next])
        XCTAssertTrue(reopened.list(owner: "b").isEmpty)
        XCTAssertTrue(reopened.list(owner: "a", query: "absent").isEmpty)
        XCTAssertTrue(reopened.list(owner: "a", at: now.addingTimeInterval(60)).isEmpty)
        XCTAssertFalse(try String(contentsOf: file).contains("Uses imperial units"))
        XCTAssertFalse(try reopened.remove(id: next.id, owner: "a"))
        XCTAssertFalse(try reopened.remove(id: next.id, owner: "a"))
        XCTAssertTrue(AskMemoryNoteStore(fileURL: file).list(owner: "a").isEmpty)
    }

    func testCorrectionFailureCanRetryAndToolListIsVersioned() throws {
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(
            fileURL: root.appendingPathComponent("notes.json"),
            storage: storage,
            correctionsEnabled: true
        )
        let old = try store.add("Old", owner: "a")
        storage.failure = .write
        XCTAssertThrowsError(try store.correct(id: old.id, text: "New", owner: "a", expectedVersion: 1))
        XCTAssertEqual(store.list(owner: "a"), [old])
        storage.failure = nil
        XCTAssertTrue(try store.execute(["action": "correct", "id": old.id, "text": "New", "version": 1], owner: "a")
            .contains("Corrected"))
        XCTAssertTrue(try store.execute(["action": "list"], owner: "a").contains("v2: New"))
        XCTAssertThrowsError(try store.add("x", owner: "a", expiry: .distantPast))
        XCTAssertThrowsError(try store.execute(["action": "invalid"], owner: "a"))
        XCTAssertNil(AskMemoryNoteStore.memoryText(store.list(owner: "a"), limit: 1))
        XCTAssertEqual(AskMemoryNoteStore.injectionNotes(store.list(owner: "a"), limit: 100).count, 1)
    }

    func testRecentLegacyMigrationAccountIsolationDeletionAndFailedCommit() throws {
        let file = root.appendingPathComponent("recent.json")
        let id = UUID(), date = Date()
        let legacy = RecentInputMemory(id: id, appIdentifier: "app", scope: "page", text: "legacy", recordedAt: date)
        try JSONEncoder().encode([legacy]).write(to: file)
        let storage = FailingMemoryNoteFileStorage()
        let store = RecentInputMemoryStore(fileURL: file, storage: storage)
        XCTAssertEqual(store.recent(scope: "page"), ["legacy"])
        XCTAssertTrue(store.recent(scope: "page", owner: "a").isEmpty)
        XCTAssertFalse(store.upsert(id: id, appIdentifier: "app", scope: "page", text: "takeover", owner: "a"))
        let generation = store.currentGeneration()
        storage.failure = .write
        XCTAssertFalse(store.delete(id: id))
        XCTAssertEqual(store.currentGeneration(), generation)
        XCTAssertEqual(store.recent(scope: "page"), ["legacy"])
        storage.failure = nil
        XCTAssertTrue(store.delete(id: id))
        let reopened = RecentInputMemoryStore(fileURL: file)
        XCTAssertFalse(reopened.upsert(id: id, appIdentifier: "app", scope: "page", text: "resurrect"))
        XCTAssertFalse(reopened.upsert(
            id: UUID(),
            appIdentifier: "app",
            scope: "page",
            text: "late",
            expectedGeneration: generation
        ))
        let otherID = UUID()
        XCTAssertTrue(reopened.upsert(id: otherID, appIdentifier: "app", scope: "page", text: "private", owner: "a"))
        XCTAssertEqual(reopened.list(owner: "a", query: "PRIVATE").count, 1)
        XCTAssertEqual(reopened.appIdentifiers(owner: "a"), ["app"])
        XCTAssertTrue(reopened.clear(owner: "local"))
        XCTAssertEqual(reopened.recent(scope: "page", owner: "a"), ["private"])
        XCTAssertTrue(reopened.list(at: date.addingTimeInterval(RecentInputMemoryStore.lifetime + 1), owner: "a")
            .isEmpty)
        XCTAssertTrue(reopened.clear(appIdentifier: "app", owner: "a"))
        XCTAssertTrue(reopened.list(owner: "a").isEmpty)
    }

    func testSoulDeleteInvalidatesAnObservationStartedBeforeDeleteAcrossReopen() {
        let file = root.appendingPathComponent("soul.json")
        let store = GlobalSoulMemoryStore(fileURL: file)
        let generation = store.currentGeneration()
        XCTAssertTrue(store.deleteSoul(ownerID: "a"))
        let reopened = GlobalSoulMemoryStore(fileURL: file)
        reopened.recordFinalInput(
            id: UUID(),
            ownerID: "a",
            appIdentifier: "app",
            text: "late AX",
            expectedGeneration: generation
        )
        XCTAssertTrue(reopened.pendingAppIdentifiers(ownerID: "a").isEmpty)
        let input = UUID()
        reopened.recordFinalInput(id: input, ownerID: "a", appIdentifier: "app", text: "fresh",
                                  expectedGeneration: reopened.currentGeneration())
        XCTAssertEqual(reopened.pendingAppIdentifiers(ownerID: "a"), ["app"])
        reopened.removeInput(id: input)
        reopened.recordFinalInput(id: input, ownerID: "a", appIdentifier: "app", text: "late duplicate")
        XCTAssertTrue(reopened.pendingAppIdentifiers(ownerID: "a").isEmpty)
    }

    func testInvalidationIsDurableOwnerScopedAndPreservesHistoryPayload() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryInvalidationStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let snapshot = AskMemory(global: "old", owner: "a", capturedAt: date)
        XCTAssertNotNil(snapshot.usable(owner: "a", invalidations: store))
        XCTAssertNil(snapshot.usable(owner: "b", invalidations: store))
        store.invalidate(owner: "a", at: date, notify: false)
        store.invalidate(owner: "a", at: date.addingTimeInterval(-1), notify: false)
        let restarted = MemoryInvalidationStore(defaults: defaults)
        XCTAssertEqual(restarted.cutoff(owner: "a"), date)
        XCTAssertNil(snapshot.usable(owner: "a", invalidations: restarted))
        XCTAssertNil(AskMemory(global: "legacy").usable(owner: "a", invalidations: restarted))
        XCTAssertNotNil(AskMemory(global: "other", owner: "b").usable(owner: "b", invalidations: restarted))
        XCTAssertNotNil(AskMemory(global: "new", owner: "a", capturedAt: date.addingTimeInterval(1)).usable(
            owner: "a",
            invalidations: restarted
        ))
        XCTAssertNil(AskMemory(global: "expired", expiry: date).usable(at: date))
        let payload = #"{"messages":[{"role":"system","content":"<user_memory>\nold"},{"role":"assistant","content":"old derived text"},{"role":"user","content":"hello"}],"temperature":0}"#
        let stripped = AskMemory.removingInjection(from: payload)
        XCTAssertFalse(stripped.contains("<user_memory>"))
        XCTAssertTrue(stripped.contains("old derived text"))
        XCTAssertTrue(stripped.contains("temperature"))
        XCTAssertEqual(AskMemory.removingInjection(from: "invalid"), "invalid")
    }

    func testLocalPurgeKeepsOtherAccountsCapturedMemory() async throws {
        let engine = AskLocalEngine(directory: root.appendingPathComponent("conversations"))
        for owner in ["a", "b"] {
            let request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question", tools: [],
                                         modelRef: "custom:model", memory: AskMemory(global: "source-" + owner, owner: owner))
            _ = try await engine.send(conversationId: owner, request: request, token: "")
        }
        let cloud = AskTestAPI()
        let routed = AskRoutedAPI(cloud: cloud, local: engine)
        try await routed.purgeMemory(owner: "a", token: "token")
        let purgeTokens = await cloud.purgeTokens
        XCTAssertEqual(purgeTokens, ["token"])
        let first = try await engine.conversation(id: "a", token: "")
        let second = try await engine.conversation(id: "b", token: "")
        XCTAssertNil(first.memory)
        XCTAssertFalse(first.run?.inference?.payload.contains("source-a") == true)
        XCTAssertEqual(second.memory?.global, "source-b")
        XCTAssertTrue(second.run?.inference?.payload.contains("source-b") == true)
    }

    func testAccountRoundTripInvalidatesEarlierAXObservation() {
        let store = RecentInputMemoryStore(fileURL: root.appendingPathComponent("session.json"))
        let generation = store.currentGeneration()
        store.invalidateObservations() // A -> B
        store.invalidateObservations() // B -> A
        XCTAssertFalse(store.upsert(id: UUID(), appIdentifier: "app", scope: "app", text: "late account B field",
                                    expectedGeneration: generation, owner: "a"))
        XCTAssertTrue(store.list(owner: "a").isEmpty)
    }

    func testSoulSchedulingExpiryAndAccountFilteredClear() throws {
        let store = GlobalSoulMemoryStore(fileURL: root.appendingPathComponent("schedule.json"))
        let now = Date()
        XCTAssertNil(store.nextWake(ownerID: "a", at: now))
        XCTAssertNil(store.nextExpiry(ownerID: "a", at: now))
        for index in 0 ..< 5 {
            store.recordFinalInput(id: UUID(), ownerID: "a", appIdentifier: index == 0 ? "first" : "second",
                                   text: "input", at: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.nextExpiry(ownerID: "a", at: now), now.addingTimeInterval(14400))
        XCTAssertEqual(store.nextWake(ownerID: "a", at: now), now.addingTimeInterval(13800))
        XCTAssertEqual(store.nextWake(ownerID: "a", allowedApps: ["first"], at: now), now.addingTimeInterval(14400))
        XCTAssertNil(store.nextWake(ownerID: "a", allowedApps: [], at: now))
        XCTAssertNil(store.readyBatch(ownerID: "a", at: now))
        let batch = try XCTUnwrap(store.readyBatch(ownerID: "a", at: now.addingTimeInterval(13800)))
        XCTAssertEqual(store.nextWake(ownerID: "a", at: now.addingTimeInterval(13800)), now.addingTimeInterval(14400))
        XCTAssertFalse(store.complete(batch, with: "expired", at: now.addingTimeInterval(15000)))
        XCTAssertNil(store.soul(ownerID: "a"))
        for _ in 0 ..< 20 { store.recordFinalInput(id: UUID(), ownerID: "a", appIdentifier: "app", text: "fresh", at: now) }
        XCTAssertEqual(store.nextWake(ownerID: "a", at: now), now)
        store.recordFinalInput(id: UUID(), ownerID: "b", appIdentifier: "app", text: "other", at: now)
        XCTAssertTrue(store.clearPending(appIdentifier: "app", ownerID: "a"))
        XCTAssertEqual(store.pendingAppIdentifiers(ownerID: "b", at: now), ["app"])
        XCTAssertTrue(store.pendingAppIdentifiers(ownerID: "a", at: now).isEmpty)
        XCTAssertTrue(store.clearPending())
        XCTAssertNil(store.nextExpiry(ownerID: "b", at: now))
    }

    func testWireFixtureAndRolloutGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/harness/fixtures/r01-memory-v1.json"))
        let memory = try AskCoding.decoder().decode(AskMemory.self, from: data)
        XCTAssertEqual(memory.sources?.first?.supersedes, "note-1")
        XCTAssertEqual(memory.sources?.last?.scope, "device/com.example.editor")
        XCTAssertEqual(memory.budget?.globalScalars, memory.global?.unicodeScalars.count)
        XCTAssertEqual(memory.budget?.appScalars, 14)
        XCTAssertEqual(memory.budget?.excerptCountLimit, AskMemory.maximumExcerpts)
        XCTAssertNotNil(memory.usable())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        XCTAssertFalse(MemoryRollout.enabled(defaults))
        defaults.set(true, forKey: MemoryRollout.defaultsKey)
        XCTAssertTrue(MemoryRollout.enabled(defaults))
        let store = AskMemoryNoteStore(fileURL: self.root.appendingPathComponent("gate.json"))
        let note = try store.add("old", owner: "a")
        XCTAssertThrowsError(try store.execute(
            ["action": "correct", "id": note.id, "text": "new", "version": 1],
            owner: "a"
        ))
        let call = AskToolCall(id: "correction", function: .init(name: "memory", arguments: #"{"action":"correct"}"#))
        XCTAssertFalse(AskToolPolicy.mayReuse(call))
    }

    func testCrashRecoveryRebuildsSnapshotTombstonesFromEachStore() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalidations = MemoryInvalidationStore(defaults: defaults)
        let notesFile = root.appendingPathComponent("notes.json")
        let notes = AskMemoryNoteStore(fileURL: notesFile)
        let note = try notes.add("secret", owner: "notes")
        try notes.remove(id: note.id, owner: "notes")
        AskMemoryNoteStore(fileURL: notesFile).recoverInvalidations(using: invalidations)
        XCTAssertNotNil(invalidations.cutoff(owner: "notes"))
        let recentFile = root.appendingPathComponent("recent.json")
        let recent = RecentInputMemoryStore(fileURL: recentFile)
        recent.clear(owner: "recent")
        RecentInputMemoryStore(fileURL: recentFile).recoverInvalidations(using: invalidations)
        XCTAssertNotNil(invalidations.cutoff(owner: "recent"))
        let soulFile = root.appendingPathComponent("soul.json")
        let soul = GlobalSoulMemoryStore(fileURL: soulFile)
        soul.deleteSoul(ownerID: "soul")
        GlobalSoulMemoryStore(fileURL: soulFile).recoverInvalidations(using: invalidations)
        XCTAssertNotNil(invalidations.cutoff(owner: "soul"))
        XCTAssertTrue(defaults.bool(forKey: "ask.memory.purgePending.notes"))
    }

    @MainActor func testSettingsCorrectionFailureKeepsEditorRetryable() throws {
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"), storage: storage)
        let note = try store.add("Old", owner: "a")
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        storage.failure = .replace
        XCTAssertFalse(model.correct(note, text: "New", expiry: nil, from: store, owner: "a"))
        XCTAssertEqual(model.notes, [note])
        XCTAssertNotNil(model.error)
        storage.failure = nil
        XCTAssertTrue(model.correct(note, text: "New", expiry: nil, from: store, owner: "a"))
        XCTAssertEqual(model.notes.first?.text, "New")
        XCTAssertNil(model.error)
    }

    @MainActor func testStructuredProviderBudgetsExplicitNotesFirstAndRemainsOptIn() throws {
        let settings = try SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        settings.globalSoulMemoryEnabled = true
        settings.recentInputMemoryEnabled = true
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"))
        _ = try notes.add(String(repeating: "n", count: 300), owner: "a")
        let recent = RecentInputMemoryStore(fileURL: root.appendingPathComponent("recent.json"))
        recent.upsert(id: UUID(), appIdentifier: "app", scope: "page", text: "excerpt", owner: "a")
        recent.upsert(id: UUID(), appIdentifier: "app", scope: "page", text: "foreign", owner: "b")
        let soul = GlobalSoulMemoryStore(fileURL: root.appendingPathComponent("soul.json"))
        for _ in 0 ..< 20 {
            soul.recordFinalInput(id: UUID(), ownerID: "a", appIdentifier: "app", text: "candidate")
        }
        XCTAssertTrue(try soul.complete(
            XCTUnwrap(soul.readyBatch(ownerID: "a")),
            with: String(repeating: "s", count: 500)
        ))
        func provider(_ enabled: Bool) -> AskMemoryProvider {
            .init(settings: settings, structuredMemoryEnabled: enabled, soulStore: soul, recentStore: recent,
                  noteStore: notes, ownerID: { "a" }, resolveScope: { .init(appIdentifier: $0, key: "page") })
        }
        let result = try XCTUnwrap(provider(true).memory(bundleIdentifier: "app", appName: "App"))
        XCTAssertTrue(result.global?.hasPrefix("Saved notes:") == true)
        XCTAssertLessThanOrEqual(result.global?.unicodeScalars.count ?? 0, 1000)
        XCTAssertEqual(result.sources?.map(\.source), [.explicit, .soul, .recent])
        XCTAssertEqual(result.app?.excerpts, ["excerpt"])
        XCTAssertEqual(result.budget?.globalScalars, result.global?.unicodeScalars.count)
        XCTAssertEqual(result.budget?.appScalars, 7)
        XCTAssertEqual(result.budget?.excerptCountLimit, 4)
        XCTAssertNotNil(result.expiry)
        XCTAssertNil(provider(false).memory(bundleIdentifier: "app", appName: nil)?.sources)
        let wire = try AskCoding.encoder().encode(result)
        XCTAssertEqual(try AskCoding.decoder().decode(AskMemory.self, from: wire).sources?.count, 3)
    }
}
