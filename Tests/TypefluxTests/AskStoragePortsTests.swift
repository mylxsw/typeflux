import Foundation
@testable import Typeflux
import XCTest

final class AskStoragePortsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-storage-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func request(temporary: Bool = false) -> AskSendRequest {
        var value = AskSendRequest(
            id: UUID().uuidString,
            deviceId: "device",
            text: "Question",
            tools: [],
            modelRef: "custom:model"
        )
        value.temporary = temporary
        return value
    }

    private func receipt(_ c: AskConversation, tokens: Int = 10) throws -> AskInferenceResult {
        let run = try XCTUnwrap(c.run)
        return try .init(
            runId: run.id,
            deviceId: "device",
            inferenceId: XCTUnwrap(run.inference?.id),
            content: "Answer",
            usage: .init(promptTokens: tokens, completionTokens: 0, totalTokens: tokens)
        )
    }

    func testFileRoundtripReopenAndBestEffortEnumeration() async throws {
        let store = FileAskLocalSnapshotStore(directory: directory)
        XCTAssertTrue(store.collectedSnapshots().isEmpty)
        let c = try await AskLocalEngine(directory: directory).send(
            conversationId: "baseline",
            request: request(),
            token: ""
        )
        let bytes = try XCTUnwrap(store.collectedSnapshots().first)
        try store.writeSnapshot(bytes, id: "baseline")
        try Data("invalid json".utf8).write(to: directory.appendingPathComponent("malformed.json"))
        try bytes.write(to: directory.appendingPathComponent("ignored.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("unreadable.json"),
            withIntermediateDirectories: true
        )
        let budgets = directory.appendingPathComponent("Budgets")
        try FileManager.default.createDirectory(at: budgets, withIntermediateDirectories: true)
        try bytes.write(to: budgets.appendingPathComponent("nested.json"))
        XCTAssertEqual(FileAskLocalSnapshotStore(directory: directory).collectedSnapshots().count, 2)
        let reopened = AskLocalEngine(directory: directory)
        let loaded = try await reopened.conversation(id: c.id, token: "")
        XCTAssertEqual(loaded.revision, c.revision)
        let history = try await reopened.list(token: "", offset: 0)
        XCTAssertEqual(history.map(\.id), ["baseline"])
        try store.removeSnapshot(id: "baseline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("baseline.json").path))
        XCTAssertThrowsError(try store.removeSnapshot(id: "baseline"))
        // A regular file cannot be enumerated as a directory, independent of chmod privileges.
        XCTAssertTrue(FileAskLocalSnapshotStore(directory: directory.appendingPathComponent("ignored.txt"))
            .collectedSnapshots().isEmpty)
    }

    func testIdentifierContractRejectsBeforeCreatingDirectoriesOrDeletingFiles() throws {
        let store = FileAskLocalSnapshotStore(directory: directory)
        let invalid = [
            "",
            "../escape",
            "/absolute",
            "a/b",
            "a\\b",
            ".",
            "a.json",
            "é",
            "中",
            "a b",
            String(repeating: "a", count: 129)
        ]
        for id in invalid {
            XCTAssertFalse(AskStorageIdentifier.isValid(id))
            XCTAssertFalse(AskLocalEngine.validID(id))
            XCTAssertThrowsError(try store.writeSnapshot(Data(), id: id)) { error in
                XCTAssertEqual(error.localizedDescription, L("ask.local.notFound"))
            }
            XCTAssertThrowsError(try store.removeSnapshot(id: id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        for id in ["A_z-09", String(repeating: "a", count: 128)] {
            XCTAssertTrue(AskLocalEngine.validID(id))
            try store.writeSnapshot(Data(id.utf8), id: id)
        }
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["A_z-09.json", String(repeating: "a", count: 128) + ".json"]))
        try store.removeSnapshot(id: "A_z-09")
        XCTAssertEqual(store.collectedSnapshots(), [Data(String(repeating: "a", count: 128).utf8)])
    }

    func testInjectedInstancesHandleSendReceiptHistoryPurgeAndCanonicalDeleteWithoutFallback() async throws {
        let snapshots = RecordingSnapshots(), budgets = RecordingBudgets()
        let engine = AskLocalEngine(
            directory: directory,
            budgetEnabled: true,
            snapshotStore: snapshots,
            budgetStore: budgets
        )
        var input = request()
        input.memory = AskMemory(global: "Remember this")
        var c = try await engine.send(conversationId: "stored", request: input, token: "")
        XCTAssertFalse(snapshots.writes.isEmpty)
        XCTAssertFalse(budgets.calls.isEmpty)
        // Reads pass no initial journal; the one that creates it is rooted at the run.
        XCTAssertTrue(budgets.calls.allSatisfy { $0.conversation == "stored" && ($0.initial == nil || $0.initial?.runId == $0.root) })
        XCTAssertTrue(budgets.calls.contains { $0.initial != nil })
        let completed = try await engine.inferenceResult(conversationId: c.id, request: receipt(c), token: "")
        XCTAssertEqual(completed.run?.budget?.actual.tokens, 10)
        let history = try await engine.list(token: "", offset: 0)
        XCTAssertEqual(history.map(\.id), ["stored"])
        c = try await engine.conversation(id: "stored", token: "")
        XCTAssertNotNil(c.memory)
        try await engine.purgeMemory(token: "")
        c = try await engine.conversation(id: "stored", token: "")
        XCTAssertNil(c.memory)
        let persisted = try AskCoding.decoder().decode(AskLocalRecord.self, from: XCTUnwrap(snapshots.values["stored"]))
        XCTAssertNil(persisted.conversation.memory)
        XCTAssertEqual(snapshots.loads, 1)
        let uuid = UUID().uuidString
        let canonical = AskConversationID.canonical(uuid)
        _ = try await engine.send(conversationId: uuid, request: request(), token: "")
        try await engine.delete(conversationId: uuid, token: "")
        XCTAssertEqual(snapshots.removals, [canonical])
        try await engine.delete(conversationId: "../escape", token: "")
        XCTAssertEqual(snapshots.removals, [canonical])
        snapshots.failRemoval = true
        try await engine.delete(conversationId: "stored", token: "")
        let afterDelete = try await engine.list(token: "", offset: 0)
        XCTAssertTrue(afterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTemporaryUsageNeverWritesSnapshotsAndKeepPersistsOnce() async throws {
        let snapshots = RecordingSnapshots(), budgets = RecordingBudgets()
        let engine = AskLocalEngine(
            directory: directory,
            budgetEnabled: true,
            snapshotStore: snapshots,
            budgetStore: budgets
        )
        let c = try await engine.send(conversationId: "temporary", request: request(temporary: true), token: "")
        let result = try receipt(c)
        _ = try await engine.inferenceResult(conversationId: c.id, request: result, token: "")
        var late = result
        late.usage = .init(promptTokens: 20, completionTokens: 0, totalTokens: 20)
        _ = try await engine.inferenceResult(conversationId: c.id, request: late, token: "")
        let usage = try await engine.usage(id: c.id, runId: nil, cursor: nil, token: "")
        XCTAssertFalse(usage.items.isEmpty)
        let history = try await engine.list(token: "", offset: 0)
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(snapshots.writes.isEmpty)
        XCTAssertFalse(budgets.calls.isEmpty, "Temporary budget journals retain their existing policy")
        _ = try await engine.keep(conversationId: c.id, token: "")
        _ = try await engine.keep(conversationId: c.id, token: "")
        XCTAssertEqual(snapshots.writes, [c.id])
        _ = try await engine.send(conversationId: "discard", request: request(temporary: true), token: "")
        try await engine.delete(conversationId: "discard", token: "")
        XCTAssertTrue(snapshots.removals.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSummaryCompletionUsesInjectedSnapshots() async throws {
        let snapshots = RecordingSnapshots()
        let engine = AskLocalEngine(directory: directory, snapshotStore: snapshots)
        var c = try await engine.send(conversationId: "summary", request: request(), token: "")
        c = try await engine.inferenceResult(conversationId: c.id, request: receipt(c), token: "")
        for _ in 1 ... 14 {
            c = try await engine.send(conversationId: c.id, request: request(), token: "")
            if c.run?.inference?.summaryThrough != nil {
                break
            }
            c = try await engine.inferenceResult(conversationId: c.id, request: receipt(c), token: "")
        }
        XCTAssertNotNil(c.run?.inference?.summaryThrough)
        c = try await engine.inferenceResult(conversationId: c.id, request: receipt(c), token: "")
        XCTAssertEqual(c.summary, "Answer")
        let persisted = try AskCoding.decoder().decode(AskLocalRecord.self, from: XCTUnwrap(snapshots.values[c.id]))
        XCTAssertEqual(persisted.conversation.summary, "Answer")
        XCTAssertTrue(snapshots.writes.allSatisfy { $0 == c.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testWriteFailureDoesNotPublishNewSnapshot() async throws {
        let snapshots = RecordingSnapshots()
        let engine = AskLocalEngine(directory: directory, snapshotStore: snapshots)
        let c = try await engine.send(conversationId: "existing", request: request(), token: "")
        let before = snapshots.values
        snapshots.failWrite = true
        do {
            _ = try await engine.inferenceResult(conversationId: c.id, request: receipt(c), token: "")
            XCTFail("Expected injected write failure")
        } catch StorageFailure.injected {}
        let loaded = try await engine.conversation(id: c.id, token: "")
        XCTAssertEqual(loaded.revision, c.revision)
        XCTAssertEqual(loaded.messages, c.messages)
        XCTAssertEqual(loaded.run?.status, c.run?.status)
        do {
            _ = try await engine.send(conversationId: "new", request: request(), token: "")
            XCTFail("Expected injected write failure")
        } catch StorageFailure.injected {}
        let history = try await engine.list(token: "", offset: 0)
        XCTAssertEqual(history.map(\.id), ["existing"])
        XCTAssertEqual(snapshots.values, before)
    }

    func testInjectedLoadSkipsMalformedPreservesUnknownBindingAndMarksRecoveryOnlyInMemory() async throws {
        let snapshots = RecordingSnapshots()
        let seed = AskLocalEngine(directory: directory, snapshotStore: snapshots)
        let c = try await seed.send(conversationId: "future", request: request(), token: "")
        var record = try AskCoding.decoder().decode(AskLocalRecord.self, from: XCTUnwrap(snapshots.values[c.id]))
        record.conversation.run?.agentBinding = .init(id: "unknown", version: 1)
        record.conversation.run?.status = "running"
        record.conversation.run?.budgetEnabled = true
        snapshots.values[c.id] = try AskCoding.encoder().encode(record)
        record.conversation.id = "recovery"
        record.conversation.run?.agentBinding = nil
        record.conversation.run?.budgetEnabled = false
        snapshots.values["recovery"] = try AskCoding.encoder().encode(record)
        snapshots.values["bad"] = Data("bad json".utf8)
        let before = snapshots.values, writes = snapshots.writes
        let loads = snapshots.loads, visits = snapshots.visits.count
        let budgets = RecordingBudgets()
        let reopened = AskLocalEngine(directory: directory, snapshotStore: snapshots, budgetStore: budgets)
        let future = try await reopened.conversation(id: c.id, token: "")
        XCTAssertEqual(future.run?.agentBinding?.id, "unknown")
        XCTAssertNil(future.run?.recovery)
        let recovery = try await reopened.conversation(id: "recovery", token: "")
        XCTAssertEqual(recovery.run?.recovery?.state, "unknown_outcome")
        let history = try await reopened.list(token: "", offset: 0)
        XCTAssertEqual(Set(history.map(\.id)), Set(["future", "recovery"]))
        do {
            _ = try await reopened.send(conversationId: c.id, request: request(), token: "")
            XCTFail("Unsupported binding must reject execution")
        } catch let error as AskLocalError { XCTAssertEqual(error.code, AskAgentBinding.errorCode) }
        XCTAssertEqual(snapshots.values, before)
        XCTAssertEqual(snapshots.writes, writes)
        XCTAssertTrue(budgets.calls.isEmpty)
        XCTAssertEqual(snapshots.loads, loads + 1)
        XCTAssertEqual(Array(snapshots.visits.dropFirst(visits)), before.keys.sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

extension AskStoragePortsTests {
    func testFileVisitorReadsNextPayloadOnlyAfterConsumerReturns() throws {
        let store = FileAskLocalSnapshotStore(directory: directory)
        let payloads = Dictionary(uniqueKeysWithValues: (0 ..< 4).map { index in
            ("snapshot-\(index)", Data("{\"id\":\"snapshot-\(index)\"}".utf8))
        })
        for (id, data) in payloads {
            try store.writeSnapshot(data, id: id)
        }
        var consumed: [Data] = []
        store.forEachSnapshot { data in
            consumed.append(data)
            guard consumed.count == 1 else { return }
            // Identify the current payload rather than assuming directory order.
            let current = payloads.first { $0.value == data }?.key
            XCTAssertNotNil(current)
            for id in payloads.keys where id != current {
                do {
                    try store.removeSnapshot(id: id)
                } catch {
                    XCTFail("Could not remove unread snapshot: \(error)")
                }
            }
        }
        XCTAssertEqual(consumed.count, 1, "Deleted files must not have been prefetched")
        XCTAssertTrue(consumed.allSatisfy { payloads.values.contains($0) })
    }
}

private enum StorageFailure: Error { case injected }

/// Accessed synchronously by one engine at a time; tests inspect only after awaited calls.
private final class RecordingSnapshots: AskLocalSnapshotStoring, @unchecked Sendable {
    var values: [String: Data] = [:]
    var writes: [String] = []
    var removals: [String] = []
    var loads = 0
    var visits: [String] = []
    var failWrite = false
    var failRemoval = false
    func forEachSnapshot(_ consume: (Data) -> Void) {
        loads += 1
        for id in values.keys.sorted() {
            if let data = values[id] {
                visits.append(id)
                consume(data)
            }
        }
    }

    func writeSnapshot(_ data: Data, id: String) throws {
        if failWrite {
            throw StorageFailure.injected
        }
        writes.append(id)
        values[id] = data
    }

    func removeSnapshot(id: String) throws {
        removals.append(id)
        if failRemoval {
            throw StorageFailure.injected
        }
        values[id] = nil
    }
}

private final class RecordingBudgets: AskBudgetJournaling, @unchecked Sendable {
    struct Call { var conversation: String; var root: String; var initial: AskBudgetController? }
    var calls: [Call] = []
    private var values: [String: AskBudgetController] = [:]
    func update(conversation: String, root: String, initial: AskBudgetController?,
                _ change: (inout AskBudgetController) throws -> Void) throws -> AskBudgetController {
        calls.append(.init(conversation: conversation, root: root, initial: initial))
        let key = conversation + "/" + root
        var value = try XCTUnwrap(values[key] ?? initial)
        do { try change(&value) } catch { values[key] = value; throw error }
        values[key] = value
        return value
    }
}

private extension AskLocalSnapshotStoring {
    func collectedSnapshots() -> [Data] {
        var snapshots: [Data] = []
        forEachSnapshot { snapshots.append($0) }
        return snapshots
    }
}
