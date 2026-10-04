import XCTest
@testable import TypefluxChat

final class ChatReasoningEffortTests: XCTestCase {
    func testOnlyExplicitReasoningCapabilityOffersControls() {
        XCTAssertTrue(ChatReasoningEffort.levels(for: nil).isEmpty)
        for capability in [nil, false] as [Bool?] {
            let model = ChatModel(id: "plain", name: "Plain", reasoning: capability, reasoningEfforts: ["high"])
            XCTAssertTrue(ChatReasoningEffort.levels(for: model).isEmpty)
            XCTAssertNil(ChatReasoningEffort.high.requestValue(for: model))
        }
    }

    func testCatalogLevelsAreOrderedDeduplicatedAndUnknownValuesIgnored() {
        let model = ChatModel(id: "reasoner", name: "Reasoner", reasoning: true,
                              reasoningEfforts: ["max", "high", "future", "low", "high", ""])
        XCTAssertEqual(ChatReasoningEffort.levels(for: model), [.low, .high, .max])
    }

    func testOlderCatalogsFallBackToThreeLevels() {
        for efforts in [nil, [], ["future", ""]] as [[String]?] {
            let model = ChatModel(id: "legacy", name: "Legacy", reasoning: true, reasoningEfforts: efforts)
            XCTAssertEqual(ChatReasoningEffort.levels(for: model), [.low, .medium, .high])
        }
    }

    func testNearestPreservesAutoAndOfferedLevelsAndPrefersLowerTies() {
        let offered: [ChatReasoningEffort] = [.low, .high, .max]
        let expected: [ChatReasoningEffort] = [.providerDefault, .low, .low, .high, .high, .max]
        for (effort, nearest) in zip(ChatReasoningEffort.allCases, expected) {
            XCTAssertEqual(effort.nearest(in: offered), nearest)
            XCTAssertEqual(effort.nearest(in: []), .providerDefault)
        }
        XCTAssertEqual(ChatReasoningEffort.low.nearest(in: [.high, .max]), .high)
        XCTAssertEqual(ChatReasoningEffort.max.nearest(in: [.low, .medium]), .medium)
        XCTAssertEqual(ChatReasoningEffort.medium.nearest(in: [.high, .low]), .low)
    }

    func testTopUsesModelsHighestLevelAndNeverAuto() {
        XCTAssertTrue(ChatReasoningEffort.high.isTop(in: [.low, .medium, .high]))
        XCTAssertTrue(ChatReasoningEffort.max.isTop(in: [.high, .max]))
        XCTAssertFalse(ChatReasoningEffort.high.isTop(in: [.high, .max]))
        XCTAssertFalse(ChatReasoningEffort.providerDefault.isTop(in: [.providerDefault]))
        XCTAssertFalse(ChatReasoningEffort.max.isTop(in: []))
    }

    func testRequestUsesNearestSupportedLevelAndOmitsAuto() {
        let model = ChatModel(id: "reasoner", name: "Reasoner", reasoning: true, reasoningEfforts: ["low", "high"])
        XCTAssertNil(ChatReasoningEffort.providerDefault.requestValue(for: model))
        XCTAssertNil(ChatReasoningEffort.high.requestValue(for: nil))
        XCTAssertEqual(ChatReasoningEffort.medium.requestValue(for: model), "low")
        XCTAssertEqual(ChatReasoningEffort.max.requestValue(for: model), "high")
    }
}
