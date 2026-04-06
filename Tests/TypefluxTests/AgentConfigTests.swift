@testable import Typeflux
import XCTest

final class AgentConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = AgentConfig.default
        XCTAssertEqual(config.maxSteps, 10)
        XCTAssertFalse(config.allowParallelToolCalls)
        XCTAssertNil(config.temperature)
        XCTAssertFalse(config.enableStreaming)
        XCTAssertEqual(config.initialStepIndex, 0)
    }

    func testCustomConfig() {
        let config = AgentConfig(
            maxSteps: 5,
            allowParallelToolCalls: true,
            temperature: 0.7,
            enableStreaming: true,
        )
        XCTAssertEqual(config.maxSteps, 5)
        XCTAssertTrue(config.allowParallelToolCalls)
        XCTAssertEqual(config.temperature, 0.7)
        XCTAssertTrue(config.enableStreaming)
        XCTAssertEqual(config.initialStepIndex, 0)
    }

    func testCustomInitialStepIndex() {
        let config = AgentConfig(
            maxSteps: 5,
            allowParallelToolCalls: true,
            temperature: 0.7,
            enableStreaming: true,
            initialStepIndex: 2,
        )

        XCTAssertEqual(config.initialStepIndex, 2)
    }
}
