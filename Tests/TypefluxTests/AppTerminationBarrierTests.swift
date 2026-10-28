import AppKit
import Foundation
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

    @Test func retriesFailedCleanupAndExitsWhenSavingSucceeds() async throws {
        let barrier = AppTerminationBarrier()
        let forced = TerminationForceCounter()
        var attempts = 0, replies: [Bool] = []
        _ = barrier.beginChecked(timeout: 0.2, hardTimeoutGrace: 0.05, retryDelay: .milliseconds(5),
                                 forceExit: { forced.increment() }) {
            attempts += 1
            return attempts == 3
        } reply: { replies.append($0) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(attempts == 3)
        #expect(replies == [true])
        #expect(forced.count == 0)
    }

    @Test func blockedCleanupHasBoundedExitAndCannotReplyTwice() async throws {
        let barrier = AppTerminationBarrier()
        let forced = TerminationForceCounter()
        var release: CheckedContinuation<Void, Never>?
        var replies: [Bool] = []
        _ = barrier.beginChecked(timeout: 0.05, hardTimeoutGrace: 0.05,
                                 forceExit: { forced.increment() }) {
            await withCheckedContinuation { release = $0 }
            return true
        } reply: { replies.append($0) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(replies == [true])
        #expect(forced.count == 1)
        release?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(replies == [true])
    }

    @Test func persistentFailureAutomaticallyExitsAtDeadline() async throws {
        let barrier = AppTerminationBarrier()
        let forced = TerminationForceCounter()
        var attempts = 0, replies: [Bool] = []
        _ = barrier.beginChecked(timeout: 0.05, hardTimeoutGrace: 0.05, retryDelay: .milliseconds(5),
                                 forceExit: { forced.increment() }) {
            attempts += 1
            return false
        } reply: { replies.append($0) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(attempts > 1)
        #expect(replies == [true])
        #expect(forced.count == 1)
    }
}

private final class TerminationForceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
