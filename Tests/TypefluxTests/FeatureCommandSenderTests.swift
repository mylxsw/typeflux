import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureCommandSenderTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    @Test func stateFloodKeepsOnlyLatestAndDeduplicatesSuccessfulSnapshots() async throws {
        var received: [Data] = []
        var gate: CheckedContinuation<Void, Never>?
        let sender = FeatureCommandSender(route: { command in
            received.append(command.payload)
            if received.count == 1 { await withCheckedContinuation { gate = $0 } }
            return Data()
        })
        sender.send(.init(destination: .host, action: "indexSnapshot", payload: Data([0])))
        try await settle()
        for value in 1...100 {
            sender.send(.init(destination: .host, action: "indexSnapshot", payload: Data([UInt8(value)])))
        }
        #expect(received == [Data([0])])
        gate?.resume()
        try await settle()
        #expect(received == [Data([0]), Data([100])])
        sender.send(.init(destination: .host, action: "indexSnapshot", payload: Data([100])))
        try await settle()
        #expect(received.count == 2)
    }

    @Test func failuresStayQuietForStateAndRetryUnacknowledgedSnapshots() async throws {
        var attempts = 0
        let sender = FeatureCommandSender(route: { _ in
            attempts += 1
            throw FeatureRPC.Failure.busy
        }, log: { _ in })
        for _ in 0..<2 {
            sender.send(.init(destination: .host, action: "status"))
            try await settle()
        }
        #expect(attempts == 2)
    }

    @Test func userActionsAreNotDroppedOrReplayedAndDiagnosticsAreBounded() async throws {
        var attempts = 0, logs = 0
        var time: TimeInterval = 0
        let sender = FeatureCommandSender(route: { _ in
            attempts += 1
            throw FeatureRPC.Failure.unavailable
        }, log: { _ in logs += 1 }, now: { time })
        for _ in 0..<10 { sender.send(.init(destination: .chat, action: "showChat")) }
        try await settle()
        #expect(attempts == 10)
        #expect(logs == 1)
        time = 11
        sender.send(.init(destination: .chat, action: "showChat"))
        try await settle()
        #expect(logs == 2)
    }

    @Test func cancellationDoesNotLogFailure() async throws {
        let sender = FeatureCommandSender(route: { _ in throw FeatureRPC.Failure.cancelled },
            log: { _ in Issue.record("Cancellation must remain quiet") })
        sender.send(.init(destination: .chat, action: "showChat"))
        try await settle()
    }
    @Test func unchangedSnapshotsRefreshAfterIntervalAndDifferentNotificationsSurvive() async throws {
        var received: [FeatureCommand] = []
        var time: TimeInterval = 0
        let sender = FeatureCommandSender(route: { received.append($0); return Data() }, now: { time })
        let snapshot = FeatureCommand(destination: .host, action: "status", payload: Data([1]))
        sender.send(snapshot)
        try await settle()
        sender.send(snapshot)
        try await settle()
        #expect(received.count == 1)
        time = 6
        sender.send(snapshot)
        sender.send(.init(destination: .host, action: "changed", payload: Data("notes".utf8)))
        sender.send(.init(destination: .host, action: "changed", payload: Data("history".utf8)))
        try await settle()
        #expect(received.count == 4)
        #expect(Set(received.filter { $0.action == "changed" }.map(\.payload)).count == 2)
    }

    @Test func failedSnapshotCanRecoverWithoutSuppressingItsNextPublication() async throws {
        var attempts = 0
        let sender = FeatureCommandSender(route: { _ in
            attempts += 1
            if attempts == 1 { throw FeatureRPC.Failure.unavailable }
            return Data()
        }, log: { _ in })
        for _ in 0..<3 {
            sender.send(.init(destination: .host, action: "indexSnapshot", payload: Data([1])))
            try await settle()
        }
        #expect(attempts == 2)
    }

}
