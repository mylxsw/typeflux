import AppKit
import Testing
@testable import Typeflux

@Suite("Application termination ownership", .exclusiveUIState)
@MainActor
struct AppTerminationBarrierTests {
    @Test func repeatedQuitWaitsForCleanupAndRepliesExactlyOnce() async throws {
        let barrier = AppTerminationBarrier()
        var cleanupCount = 0, replies = 0
        var release: CheckedContinuation<Void, Never>?
        let first = barrier.begin {
            cleanupCount += 1
            await withCheckedContinuation { release = $0 }
        } reply: { replies += 1 }
        let second = barrier.begin { Issue.record("Cleanup was duplicated") } reply: {
            Issue.record("Quit reply was duplicated")
        }
        #expect(first == .terminateLater && second == .terminateLater)
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cleanupCount == 1 && replies == 0)
        release?.resume()
        for _ in 0..<100 where replies == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(replies == 1)
    }
}


extension AppTerminationBarrierTests {
    @Test func failedQuitOffersSafeRecoveryAndExplicitForceChoice() {
        let alert = AppQuitFailurePrompt.makeAlert()
        #expect(alert.alertStyle == .warning)
        #expect(alert.messageText == L("feature.quitBlocked.title"))
        #expect(alert.informativeText == L("feature.quitBlocked.message"))
        #expect(alert.buttons.map(\.title) == [L("feature.quitBlocked.keepOpen"),
                                               L("feature.quitBlocked.retry"),
                                               L("feature.quitBlocked.force")])
    }

    @Test func failedSaveCancelsQuitAndAllowsAnExplicitRetry() async throws {
        let barrier = AppTerminationBarrier()
        var replies: [Bool] = []
        #expect(barrier.beginChecked(cleanup: { false }, reply: { replies.append($0) }) == .terminateLater)
        for _ in 0..<100 where replies.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(replies == [false])
        #expect(barrier.beginChecked(cleanup: { true }, reply: { replies.append($0) }) == .terminateLater)
        for _ in 0..<100 where replies.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(replies == [false, true])
    }
}
