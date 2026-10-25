import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct FeatureShutdownBarrierTests {
    @Test func cancelledRequestAndRetryShareCleanup() async throws {
        let barrier = FeatureShutdownBarrier()
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let first = Task {
            try await barrier.run {
                calls += 1
                await withCheckedContinuation { release = $0 }
                try Task.checkCancellation()
            }
        }
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(release != nil)
        first.cancel()
        let retry = Task { try await barrier.run { calls += 1 } }
        release?.resume()
        try await first.value
        try await retry.value
        try await barrier.run { calls += 1 }
        #expect(calls == 1)
    }

    @Test func failedCleanupCanBeRetried() async throws {
        let barrier = FeatureShutdownBarrier()
        await #expect(throws: FeatureRPC.Failure.busy) {
            try await barrier.run { throw FeatureRPC.Failure.busy }
        }
        var saved = false
        try await barrier.run { saved = true }
        #expect(saved)
    }
}
