import Foundation
@testable import Typeflux
import XCTest

final class AskLocalLateUsageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine() -> AskLocalEngine {
        AskLocalEngine(directory: directory, budgetEnabled: true)
    }

    private func send(_ engine: AskLocalEngine, id: String) async throws -> AskConversation {
        try await engine.send(conversationId: id, request: .init(
            id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:test"
        ), token: "")
    }

    private func receipt(_ conversation: AskConversation, content: String = "Old answer") throws -> AskInferenceResult {
        let run = try XCTUnwrap(conversation.run)
        return try .init(runId: run.id, deviceId: run.deviceId, inferenceId: XCTUnwrap(run.inference?.id),
                         content: content, usage: .init(promptTokens: 5, completionTokens: 5, totalTokens: 10))
    }

    private func assertContentUnchanged(_ actual: AskConversation, _ expected: AskConversation,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        var actual = actual, expected = expected
        actual.run?.budget = nil
        expected.run?.budget = nil
        let encoder = AskCoding.encoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(actual), try encoder.encode(expected), file: file, line: line)
    }

    func testCancelRetryThenLateUsageAcrossRestartBoundaries() async throws {
        for restartAt in 0 ... 2 {
            var engine = engine()
            let id = "conversation-\(restartAt)"
            let initial = try await send(engine, id: id)
            let old = try receipt(initial)
            _ = try await engine.cancel(conversationId: id, runId: old.runId, token: "")
            if restartAt == 1 { engine = self.engine() }
            let retry = try await engine.retry(conversationId: id, runId: old.runId,
                                               deviceId: "device", modelRef: nil, token: "")
            XCTAssertNotEqual(retry.run?.id, old.runId)
            XCTAssertEqual(retry.run?.budgetRootId, initial.run?.budgetRootId)
            XCTAssertEqual(retry.run?.budgetDeadline, initial.run?.budgetDeadline)
            if restartAt == 2 { engine = self.engine() }
            let latest = try await engine.conversation(id: id, token: "")
            let settled = try await engine.inferenceResult(conversationId: id, request: old, token: "")
            try assertContentUnchanged(settled, latest)
            XCTAssertEqual(settled.run?.budget?.actual.tokens, 10)
            XCTAssertEqual(settled.run?.budget?.occupied, latest.run?.budget?.occupied)
            XCTAssertEqual(settled.run?.budget?.pending, 2)
            let duplicate = try await engine.inferenceResult(conversationId: id, request: old, token: "")
            XCTAssertEqual(duplicate, settled)
            let reopened = self.engine()
            let persisted = try await reopened.conversation(id: id, token: "")
            try assertContentUnchanged(persisted, latest)
            XCTAssertEqual(persisted.run?.budget, settled.run?.budget)
            let replay = try await reopened.inferenceResult(conversationId: id, request: old, token: "")
            XCTAssertEqual(replay, persisted)
        }
    }

    func testLateUsageRacesNewCompletionOrCancellationWithoutChangingItsOutcome() async throws {
        for cancel in [false, true] {
            let engine = engine()
            let id = cancel ? "cancel" : "complete"
            let initial = try await send(engine, id: id)
            let old = try receipt(initial)
            _ = try await engine.cancel(conversationId: id, runId: old.runId, token: "")
            let retry = try await engine.retry(conversationId: id, runId: old.runId,
                                               deviceId: "device", modelRef: nil, token: "")
            let current = try receipt(retry, content: "New answer")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 8 {
                    group.addTask {
                        _ = try await engine.inferenceResult(conversationId: id, request: old, token: "")
                    }
                }
                group.addTask {
                    if cancel {
                        _ = try await engine.cancel(conversationId: id, runId: current.runId, token: "")
                    } else {
                        _ = try await engine.inferenceResult(conversationId: id, request: current, token: "")
                    }
                }
                try await group.waitForAll()
            }
            let final = try await engine.conversation(id: id, token: "")
            XCTAssertEqual(final.run?.id, current.runId)
            XCTAssertEqual(final.run?.status, cancel ? "cancelled" : "completed")
            XCTAssertEqual(final.messages.filter { $0.role == "assistant" }.map(\.text), cancel ? [] : ["New answer"])
            XCTAssertEqual(final.run?.budget?.actual.tokens, cancel ? 10 : 20)
            XCTAssertEqual(final.run?.budget?.occupied, retry.run?.budget?.occupied)
            let late = try await engine.inferenceResult(conversationId: id, request: old, token: "")
            XCTAssertEqual(late, final)
            let persisted = try await self.engine().conversation(id: id, token: "")
            try assertContentUnchanged(persisted, final)
            XCTAssertEqual(persisted.run?.budget, final.run?.budget)
        }
    }

    func testMissingUnknownAndInvalidUsageNeverRefundsReservations() async throws {
        let engine = engine()
        let initial = try await send(engine, id: "conversation")
        var old = try receipt(initial)
        _ = try await engine.cancel(conversationId: initial.id, runId: old.runId, token: "")
        let retry = try await engine.retry(conversationId: initial.id, runId: old.runId,
                                           deviceId: "device", modelRef: nil, token: "")
        old.usage = nil
        old.failed = true
        let missing = try await engine.inferenceResult(conversationId: initial.id, request: old, token: "")
        try assertContentUnchanged(missing, retry)
        XCTAssertEqual(missing.run?.budget?.actual.tokens, 0)
        XCTAssertEqual(missing.run?.budget?.occupied, retry.run?.budget?.occupied)
        XCTAssertEqual(missing.run?.budget?.pending, 2)
        let store = AskBudgetStore(directory: directory)
        let root = try XCTUnwrap(initial.run?.budgetRootId)
        let journal = try store.update(conversation: initial.id, root: root) { _ in }
        let reservation = try XCTUnwrap(journal.reservations[old.inferenceId])
        XCTAssertEqual(reservation.state, "pending")
        XCTAssertFalse(reservation.tokensFinal)
        XCTAssertFalse(reservation.costFinal)
        old.usage = .init(promptTokens: -1, completionTokens: 5, totalTokens: 10)
        await assertRejected(engine, id: initial.id, receipt: old)
        var unknown = old
        unknown.usage = nil
        unknown.inferenceId = "unknown"
        await assertRejected(engine, id: initial.id, receipt: unknown)
        XCTAssertEqual(try store.update(conversation: initial.id, root: root) { _ in }, journal)
        old.usage = .init(promptTokens: 5, completionTokens: 5, totalTokens: 10)
        let later = try await engine.inferenceResult(conversationId: initial.id, request: old, token: "")
        XCTAssertEqual(later.run?.budget?.actual.tokens, 10)
        XCTAssertEqual(later.run?.budget?.occupied, retry.run?.budget?.occupied)
    }

    private func assertRejected(_ engine: AskLocalEngine, id: String, receipt: AskInferenceResult,
                                token: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await engine.inferenceResult(conversationId: id, request: receipt, token: token)
            XCTFail("An unbound receipt must be rejected", file: file, line: line)
        } catch {}
    }

    func testReceiptCannotChooseAnotherDeviceRunConversationOrCloudAccount() async throws {
        let engine = engine()
        let initial = try await send(engine, id: "first")
        let other = try await send(engine, id: "second")
        let valid = try receipt(initial)
        var wrong = valid
        wrong.deviceId = "other-device"
        await assertRejected(engine, id: initial.id, receipt: wrong)
        wrong = valid
        wrong.runId = other.run!.id
        await assertRejected(engine, id: initial.id, receipt: wrong)
        wrong = valid
        wrong.inferenceId = other.run!.inference!.id
        await assertRejected(engine, id: initial.id, receipt: wrong)
        await assertRejected(engine, id: other.id, receipt: valid)
        await assertRejected(engine, id: initial.id, receipt: valid, token: "cloud-account")
        let cloud = AskTestAPI()
        await cloud.seed(initial)
        let routed = AskRoutedAPI(cloud: cloud, local: engine)
        _ = try await routed.inferenceResult(conversationId: initial.id, request: valid, token: "cloud-account")
        let cloudReceipts = await cloud.inferenceResults
        XCTAssertEqual(cloudReceipts, [valid])
        let unchanged = try await engine.conversation(id: initial.id, token: "")
        XCTAssertEqual(unchanged, initial)
        let otherUnchanged = try await engine.conversation(id: other.id, token: "")
        XCTAssertEqual(otherUnchanged, other)
    }

    func testEveryPersistedIdentityComponentAndOperationKindMustMatch() async throws {
        let engine = engine()
        let initial = try await send(engine, id: "conversation")
        let old = try receipt(initial)
        _ = try await engine.cancel(conversationId: initial.id, runId: old.runId, token: "")
        _ = try await engine.retry(conversationId: initial.id, runId: old.runId,
                                   deviceId: "device", modelRef: nil, token: "")
        let store = AskBudgetStore(directory: directory)
        let root = try XCTUnwrap(initial.run?.budgetRootId)
        let journal = try store.update(conversation: initial.id, root: root) { _ in }
        let original = try XCTUnwrap(journal.reservations[old.inferenceId])
        let changes: [(inout AskBudgetReservation) -> Void] = [
            { $0.identity?.owner = "foreign" }, { $0.identity?.conversationId = "foreign" },
            { $0.identity?.rootId = "foreign" }, { $0.identity?.runId = "foreign" },
            { $0.identity?.deviceId = "foreign" }, { $0.runId = "foreign" },
            { $0.callId = "foreign" }, { $0.kind = "web_search" }, { $0.state = "released" },
            { $0.identity = nil }
        ]
        for change in changes {
            let before = try store.update(conversation: initial.id, root: root) { journal in
                var altered = original
                change(&altered)
                journal.reservations[old.inferenceId] = altered
            }
            await assertRejected(engine, id: initial.id, receipt: old)
            XCTAssertEqual(try store.update(conversation: initial.id, root: root) { _ in }, before)
        }
        _ = try store.update(conversation: initial.id, root: root) { $0.reservations[old.inferenceId] = original }
        let settled = try await engine.inferenceResult(conversationId: initial.id, request: old, token: "")
        XCTAssertEqual(settled.run?.budget?.actual.tokens, 10)
    }

    func testLegacyCurrentRunIdentityIsCapturedBeforeRetryReplacesIt() async throws {
        let first = engine()
        let initial = try await send(first, id: "conversation")
        let old = try receipt(initial)
        _ = try await first.cancel(conversationId: initial.id, runId: old.runId, token: "")
        let store = AskBudgetStore(directory: directory)
        let root = try XCTUnwrap(initial.run?.budgetRootId)
        _ = try store.update(conversation: initial.id, root: root) { $0.reservations[old.inferenceId]?.identity = nil }
        let restarted = engine()
        _ = try await restarted.retry(conversationId: initial.id, runId: old.runId,
                                       deviceId: "device", modelRef: nil, token: "")
        let again = engine()
        let settled = try await again.inferenceResult(conversationId: initial.id, request: old, token: "")
        XCTAssertEqual(settled.run?.budget?.actual.tokens, 10)
        let journal = try store.update(conversation: initial.id, root: root) { _ in }
        XCTAssertEqual(journal.reservations[old.inferenceId]?.identity?.owner, AskRoutedAPI.localOwner)
        XCTAssertEqual(journal.reservations[old.inferenceId]?.identity?.deviceId, old.deviceId)
    }
}
