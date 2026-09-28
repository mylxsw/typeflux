@testable import Typeflux
import Foundation
import XCTest

final class GlobalSoulMemoryTests: XCTestCase {
    private func makeStore() -> (GlobalSoulMemoryStore, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (GlobalSoulMemoryStore(fileURL: file), file)
    }

    func testTwentyInputsTriggerOneNonOverlappingUpdate() throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 10_000)
        for index in 0 ..< 19 {
            store.recordFinalInput(
                id: UUID(), ownerID: "user-a", appIdentifier: index.isMultiple(of: 2) ? "app-a" : "app-b",
                text: "input \(index)", at: start.addingTimeInterval(Double(index))
            )
        }
        XCTAssertNil(store.readyBatch(ownerID: "user-a", at: start.addingTimeInterval(19)))
        store.recordFinalInput(
            id: UUID(), ownerID: "user-a", appIdentifier: "app-b",
            text: "input 19", at: start.addingTimeInterval(19)
        )
        let batch = try XCTUnwrap(store.readyBatch(ownerID: "user-a", at: start.addingTimeInterval(20)))
        XCTAssertEqual(batch.inputs.count, 20)
        XCTAssertTrue(store.complete(batch, with: "The user develops software.", at: start.addingTimeInterval(21)))
        XCTAssertEqual(store.soul(ownerID: "user-a")?.text, "The user develops software.")
        XCTAssertNil(store.readyBatch(ownerID: "user-a", at: start.addingTimeInterval(22)))

        for index in 0 ..< 20 {
            store.recordFinalInput(
                id: UUID(), ownerID: "user-a", appIdentifier: "app-a",
                text: "new \(index)", at: start.addingTimeInterval(30 + Double(index))
            )
        }
        let next = try XCTUnwrap(store.readyBatch(ownerID: "user-a", at: start.addingTimeInterval(50)))
        XCTAssertTrue(Set(batch.inputs.map(\.id)).isDisjoint(with: Set(next.inputs.map(\.id))))
        XCTAssertEqual(next.previousSoul, "The user develops software.")
    }

    func testPreExpiryRequiresFiveAndNeverExtendsFourHourLifetime() throws {
        XCTAssertEqual(GlobalSoulMemoryStore.pendingLifetime, 4 * 60 * 60)
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 10_000)
        for index in 0 ..< 4 {
            store.recordFinalInput(
                id: UUID(), ownerID: "user-a", appIdentifier: "app-a",
                text: "input \(index)", at: start
            )
        }
        let preExpiry = start.addingTimeInterval(GlobalSoulMemoryStore.pendingLifetime - 60)
        XCTAssertNil(store.readyBatch(ownerID: "user-a", at: preExpiry))
        store.recordFinalInput(id: UUID(), ownerID: "user-a", appIdentifier: "app-a", text: "fifth", at: start)
        let batch = try XCTUnwrap(store.readyBatch(ownerID: "user-a", at: preExpiry))
        XCTAssertEqual(batch.inputs.count, 5)
        let expiry = start.addingTimeInterval(GlobalSoulMemoryStore.pendingLifetime)
        XCTAssertNil(store.readyBatch(ownerID: "user-a", at: expiry))
        XCTAssertFalse(store.complete(batch, with: "stale", at: expiry))
    }

    func testDeletingSoulInvalidatesInFlightBatchAndClearsPending() throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 10_000)
        for index in 0 ..< 20 {
            store.recordFinalInput(id: UUID(), ownerID: "user-a", appIdentifier: "app-a", text: "\(index)", at: start)
        }
        let batch = try XCTUnwrap(store.readyBatch(ownerID: "user-a", at: start))
        store.deleteSoul(ownerID: "user-a")
        XCTAssertFalse(store.complete(batch, with: "resurrected", at: start))
        XCTAssertNil(store.soul(ownerID: "user-a"))
        XCTAssertNil(store.readyBatch(ownerID: "user-a", at: start))
    }

    func testAccountsAndExcludedAppsDoNotMix() throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 10_000)
        for index in 0 ..< 20 {
            store.recordFinalInput(
                id: UUID(), ownerID: index.isMultiple(of: 2) ? "user-a" : "user-b",
                appIdentifier: index < 10 ? "allowed" : "excluded", text: "\(index)", at: start
            )
        }
        XCTAssertNil(store.readyBatch(ownerID: "user-a", at: start))
        XCTAssertNil(store.readyBatch(ownerID: "user-b", at: start))
        XCTAssertNil(store.readyBatch(ownerID: "user-a", allowedApps: ["allowed"], at: start))
        XCTAssertEqual(store.pendingAppIdentifiers(ownerID: "user-a", at: start), ["allowed", "excluded"])
    }

    func testRepeatedObservationOfOneInputCountsOnceAndPersists() throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 10_000)
        let id = UUID()
        store.recordFinalInput(id: id, ownerID: "user-a", appIdentifier: "app-a", text: "final", at: start)
        store.recordFinalInput(id: id, ownerID: "user-a", appIdentifier: "app-a", text: "duplicate", at: start)
        for index in 0 ..< 18 {
            store.recordFinalInput(
                id: UUID(), ownerID: "user-a", appIdentifier: "app-a", text: "\(index)", at: start
            )
        }
        let reopened = GlobalSoulMemoryStore(fileURL: file)
        XCTAssertNil(reopened.readyBatch(ownerID: "user-a", at: start))
        reopened.recordFinalInput(id: UUID(), ownerID: "user-a", appIdentifier: "app-a", text: "twentieth", at: start)
        let batch = try XCTUnwrap(reopened.readyBatch(ownerID: "user-a", at: start))
        XCTAssertEqual(batch.inputs.count, 20)
        XCTAssertEqual(batch.inputs.filter { $0.id == id }.map(\.text), ["final"])
    }

    func testGlobalSoulIsPromptDataBelowCurrentSpeech() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript, sourceText: "今天继续这个项目",
            spokenInstruction: nil, personaPrompt: nil,
            globalSoul: "用户长期从事软件开发"
        )
        let prompts = PromptCatalog.rewritePrompts(for: request)
        XCTAssertTrue(prompts.user.contains("用户长期从事软件开发"))
        XCTAssertTrue(prompts.user.contains("Current speech, explicit instructions, and active input context take priority"))
    }

    func testLongFinalInputKeepsBothEndsWithinBudget() {
        let input = "opening " + String(repeating: "middle ", count: 100) + "closing"
        let compact = GlobalSoulMemoryStore.compactInput(input)
        XCTAssertLessThanOrEqual(compact.count, GlobalSoulMemoryStore.maximumInputLength)
        XCTAssertTrue(compact.hasPrefix("opening "))
        XCTAssertTrue(compact.hasSuffix("closing"))
    }
}
