@testable import Typeflux
import XCTest

@MainActor
final class AskCloudflareConnectionTestTests: XCTestCase {
    private let config = AskSearchConfiguration(provider: .cloudflare, apiKey: "fixture-token", cloudflare: .init(accountID: "0123456789abcdef0123456789abcdef"))

    func testSuccessFailureAndMissingConfiguration() async throws {
        let success = AskCloudflareConnectionTest { configuration in
            XCTAssertEqual(configuration.cloudflare.provider, "ceramic")
        }
        success.start(.init())
        XCTAssertFalse(success.testing)
        XCTAssertEqual(success.result, L("ask.settings.search.cloudflare.invalid"))
        success.start(config)
        XCTAssertTrue(success.testing)
        XCTAssertNil(success.result)
        for _ in 0..<100 where success.testing { await Task.yield() }
        XCTAssertFalse(success.testing)
        XCTAssertEqual(success.result, L("ask.settings.search.cloudflare.connected"))
        success.reset()
        XCTAssertNil(success.result)
        let failure = AskCloudflareConnectionTest { _ in throw AskLocalError.message("Fixture failure") }
        failure.start(config)
        for _ in 0..<100 where failure.testing { await Task.yield() }
        XCTAssertEqual(failure.result, "Fixture failure")
        XCTAssertFalse(failure.testing)
    }

    func testChangingConfigurationDiscardsLateResult() async throws {
        let gate = SearchGate()
        let model = AskCloudflareConnectionTest { _ in await gate.wait() }
        model.start(config)
        await gate.waitUntilStarted()
        model.reset()
        XCTAssertFalse(model.testing)
        await gate.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.result)
        XCTAssertFalse(model.testing)
    }
}

private actor SearchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
