@testable import Typeflux
import XCTest

final class AskBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func controller() -> AskBudgetController {
        .init(runId: "run", limits: .init(tokens: 1000, microcredits: 1000, webRequests: 2, children: 1, operations: 10), deadline: now.addingTimeInterval(60))
    }
    private func reservation(_ id: String = "op", _ resources: AskBudgetResources = .init(tokens: 900, microcredits: 900)) -> AskBudgetReservation {
        .init(runId: "run", operationId: id, stepId: "1", callId: "call", kind: "model", reserved: resources)
    }
    func testPendingSurvivesRestartAndLateSettlementIsIdempotent() throws {
        var budget = controller()
        try budget.reserve(reservation(), at: now); try budget.reserve(reservation(), at: now)
        try budget.start("op", at: now)
        XCTAssertThrowsError(try budget.release("op")); XCTAssertThrowsError(try budget.start("op", at: now))
        budget = try AskCoding.decoder().decode(AskBudgetController.self, from: AskCoding.encoder().encode(budget))
        try budget.settle("op", actual: .init(tokens: 20), source: "client", tokensFinal: true, costFinal: true)
        XCTAssertEqual(budget.occupied.tokens, 900); XCTAssertEqual(budget.summary.metering, "client_reported")
        for _ in 0..<2 { try budget.settle("op", actual: .init(tokens: 100, microcredits: 50), source: "provider", tokensFinal: true, costFinal: true) }
        XCTAssertEqual(budget.occupied.tokens, 100); XCTAssertEqual(budget.summary.pending, 0)
        try budget.settle("op", actual: .init(tokens: 1200), source: "provider", tokensFinal: true, costFinal: true)
        XCTAssertEqual(budget.stopReason, "tokens"); XCTAssertEqual(budget.summary.actual.tokens, 1200)
        XCTAssertThrowsError(try budget.reserve(reservation("later"), at: now))
    }
    func testReleaseDeadlineAndInvalidJournal() throws {
        var budget = controller()
        XCTAssertThrowsError(try budget.reserve(reservation("bad", .init(tokens: -1)), at: now))
        XCTAssertThrowsError(try budget.start("missing", at: now)); XCTAssertThrowsError(try budget.release("missing"))
        XCTAssertThrowsError(try budget.settle("missing", actual: .init(), source: "provider", tokensFinal: true, costFinal: true))
        try budget.reserve(reservation(), at: now)
        XCTAssertThrowsError(try budget.settle("op", actual: .init(), source: "provider", tokensFinal: true, costFinal: true))
        try budget.release("op"); try budget.release("op"); XCTAssertEqual(budget.occupied.tokens, 0)
        XCTAssertThrowsError(try budget.reserve(reservation(), at: now))
        try budget.reserve(reservation("expired"), at: now)
        XCTAssertThrowsError(try budget.start("expired", at: now.addingTimeInterval(60)))
        XCTAssertEqual(budget.stopReason, "duration")
        budget.version = 2; XCTAssertFalse(budget.valid)
        for (value, reason) in [(AskBudgetResources(tokens: 1), "tokens"), (.init(microcredits: 1), "cost_estimate"),
                                (.init(webRequests: 1), "web_requests"), (.init(children: 1), "children"), (.init(operations: 1), "operations")] {
            XCTAssertEqual(value.exceeds(.init()), reason)
        }
    }
    func testDiskStoreSerializesConcurrentReservationsAndPersistsStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AskBudgetStore(directory: directory)
        let initial = controller(), now = self.now
        _ = try store.update(conversation: "c", root: "run", initial: initial) { _ in }
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            _ = try? store.update(conversation: "c", root: "run") { budget in
                let id = String(index)
                try budget.reserve(.init(operationId: id, stepId: "1", callId: id, kind: "web", reserved: .init(webRequests: 1)), at: now)
                try budget.start(id, at: now)
            }
        }
        let result = try store.update(conversation: "c", root: "run") { _ in }
        XCTAssertEqual(result.occupied.webRequests, 2); XCTAssertEqual(result.summary.pending, 2)
        XCTAssertEqual(result.stopReason, "web_requests")
        XCTAssertThrowsError(try store.update(conversation: "../escape", root: "run") { _ in })
        XCTAssertThrowsError(try store.update(conversation: "c", root: "missing") { _ in })
        XCTAssertThrowsError(try store.update(conversation: "c", root: "different", initial: initial) { _ in })
    }
    func testContextPlannerPreservesToolsGoalsRefusalsAndHandlesImages() throws {
        var messages: [[String: Any]] = [["role": "system", "content": "Do not publish"], ["role": "user", "content": "Compare sources"]]
        for _ in 0..<27 {
            messages.append(["role": "assistant", "tool_calls": [["id": "call", "function": ["arguments": "{}"]]]])
            messages.append(["role": "tool", "tool_call_id": "call", "content": String(repeating: "巨", count: 50000)])
        }
        let payload: [String: Any] = ["messages": messages, "max_tokens": 2048]
        let plan = try AskContextPlanner.plan(payload, limits: .init(window: 16000, maxOutput: 2048, known: true))
        XCTAssertTrue(plan.trimmed); XCTAssertLessThanOrEqual(plan.inputTokens + plan.outputReserve + 256, 16000)
        XCTAssertEqual((plan.payload["messages"] as? [[String: Any]])?.count, messages.count)
        XCTAssertEqual(messages[3]["content"] as? String, String(repeating: "巨", count: 50000))
        let image: [String: Any] = ["messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,x"]]]]], "max_tokens": 100000]
        let trimmed = try AskContextPlanner.plan(image, limits: .init(window: 8000))
        XCTAssertTrue(trimmed.trimmed); XCTAssertEqual(trimmed.outputReserve, 2000)
        for role in ["user", "system", "tool"] {
            XCTAssertThrowsError(try AskContextPlanner.plan(["messages": [["role": role, "content": "Tool failed: " + String(repeating: "constraint", count: 10000)]]], limits: .init(window: 4096)))
        }
        XCTAssertThrowsError(try AskContextPlanner.plan(["tools": String(repeating: "schema", count: 50000)], limits: .init()))
        XCTAssertThrowsError(try AskContextPlanner.plan([:], limits: .init(window: 0)))
        XCTAssertEqual(AskContextPlanner.excerpt("short", size: 100), "short")
        XCTAssertFalse(AskContextPlanner.excerpt(String(repeating: "𐀀", count: 100), size: 61).contains("�"))
    }
}
