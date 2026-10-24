import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskRecoveryReadTests {
    private let route = AskRoute(account: "owner", owner: "owner", token: "fixture-token")

    private func makeFixture() async throws -> Kit {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let client = try FeatureRPC(descriptor: sockets[0]), server = try FeatureRPC(descriptor: sockets[1])
        let peer = JournalReadPeer(base: try AskConversationCache.inMemory())
        await client.start { _, data in data }
        await server.start { try await peer.handle($0, payload: $1) }
        let fixture = try AskTestFixture(cacheOverride: FeatureAskCache(connection: client, generation: { 0 }))
        let value = AskConversation(id: "conversation", title: "Fixture", revision: 1, updatedAt: Date(), messages: [])
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.recoveryReadRetryDelays = [.milliseconds(2), .milliseconds(2), .milliseconds(2)]
        #expect(fixture.model.error == nil)
        return Kit(fixture: fixture, peer: peer, client: client, server: server, value: value)
    }

    private struct Kit {
        let fixture: AskTestFixture
        let peer: JournalReadPeer
        let client: FeatureRPC
        let server: FeatureRPC
        let value: AskConversation
        func stop() async { await client.stop(); await server.stop() }
    }

    @Test func transientFailureRecoversInTheSameModelWithoutReplayingWork() async throws {
        let kit = try await makeFixture()
        let fixture = kit.fixture, peer = kit.peer, value = kit.value
        defer { fixture.model.resetSession() }
        fixture.model.draft.text = "Keep my unsent question"
        fixture.model.automaticRecoveryEnabled = true
        await peer.arm(failures: 1)
        await fixture.model.refreshRecovery(value, route: route)
        #expect(fixture.model.selectedRecoveryEntries.contains { $0.readUnavailable })
        #expect(fixture.model.error == L("ask.cache.failed"))
        try await fixture.wait { fixture.model.recoveryReadRetries.isEmpty }
        #expect(fixture.model.error == nil && fixture.model.selectedRecoveryEntries.isEmpty)
        #expect(fixture.model.selectedId == value.id && fixture.model.draft.text == "Keep my unsent question")
        #expect(await peer.reads == 2)
        #expect(await peer.otherMethods.isEmpty)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.sends.isEmpty)
        #expect(await fixture.api.results.isEmpty)
        await kit.stop()
    }

    @Test func cancelledReadDoesNotMisreportStorageFailureAndRecoversWithoutReopening() async throws {
        let kit = try await makeFixture()
        let fixture = kit.fixture, peer = kit.peer, value = kit.value
        defer { fixture.model.resetSession() }
        await peer.arm(failures: 0, suspendFirst: true)
        let read = Task { await fixture.model.refreshRecovery(value, route: route) }
        try await peer.waitForRead()
        read.cancel(); await read.value
        #expect(fixture.model.error == nil)
        #expect(fixture.model.selectedRecoveryEntries.contains { $0.readUnavailable })
        try await fixture.wait { fixture.model.recoveryReadRetries.isEmpty }
        #expect(fixture.model.selectedRecoveryEntries.isEmpty && fixture.model.error == nil)
        #expect(await peer.reads == 2)
        await peer.release()
        await kit.stop()
    }

    @Test func permanentFailureKeepsExecutionClosedAndHasABoundedRetryBudget() async throws {
        let kit = try await makeFixture()
        let fixture = kit.fixture, peer = kit.peer, value = kit.value
        defer { fixture.model.resetSession() }
        await peer.arm(failures: 100)
        await fixture.model.refreshRecovery(value, route: route)
        try await fixture.wait { fixture.model.recoveryReadRetries.isEmpty }
        #expect(await peer.reads == 4)
        #expect(fixture.model.error == L("ask.cache.failed"))
        #expect(fixture.model.selectedRecoveryEntries.contains { $0.readUnavailable })
        #expect(fixture.model.recoveryBlocksResume(value))
        #expect(await peer.otherMethods.isEmpty && fixture.tools.executions == 0)
        await kit.stop()
    }

    @Test func lateCancelledReadCannotPutAWarningOnANewChat() async throws {
        let kit = try await makeFixture()
        let fixture = kit.fixture, peer = kit.peer, value = kit.value
        defer { fixture.model.resetSession() }
        await peer.arm(failures: 0, suspendFirst: true)
        let read = Task { await fixture.model.refreshRecovery(value, route: route) }
        try await peer.waitForRead()
        fixture.model.newConversation()
        read.cancel(); await read.value
        #expect(fixture.model.selectedId == nil && fixture.model.error == nil)
        #expect(fixture.model.recoveryReadRetries.isEmpty)
        await peer.release()
        await kit.stop()
    }

    @Test func olderFailureCannotOverwriteANewerSuccessfulRead() async throws {
        let kit = try await makeFixture()
        let fixture = kit.fixture, peer = kit.peer, value = kit.value
        defer { fixture.model.resetSession() }
        await peer.arm(failures: 0, suspendFirst: true)
        let old = Task { await fixture.model.refreshRecovery(value, route: route) }
        try await peer.waitForRead()
        await fixture.model.refreshRecovery(value, route: route)
        await peer.release(); await old.value
        #expect(fixture.model.error == nil && fixture.model.selectedRecoveryEntries.isEmpty)
        #expect(fixture.model.recoveryReadRetries.isEmpty)
        await kit.stop()
    }

    @Test func sessionResetCancelsPendingReadsAndCannotRestoreTheOldAccount() async throws {
        let kit = try await makeFixture()
        let fixture = kit.fixture, peer = kit.peer, value = kit.value
        await peer.arm(failures: 100)
        fixture.model.recoveryReadRetryDelays = [.seconds(30)]
        await fixture.model.refreshRecovery(value, route: route)
        fixture.model.resetSession()
        #expect(fixture.model.recoveryReadRetries.isEmpty && fixture.model.recoveryReadTokens.isEmpty)
        #expect(fixture.model.recoveryEntries.isEmpty)
        #expect(await peer.reads == 1)
        await kit.stop()
    }
}

private actor JournalReadPeer {
    let base: any AskCaching
    private(set) var reads = 0
    private(set) var otherMethods: [String] = []
    private var failures = 0
    private var suspendFirst = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: any AskCaching) { self.base = base }
    func arm(failures: Int, suspendFirst: Bool = false) {
        self.failures = failures; self.suspendFirst = suspendFirst
        reads = 0; otherMethods = []
    }
    func handle(_ method: String, payload: Data) async throws -> Data {
        if method == "cache.executions.1" {
            reads += 1
            if suspendFirst, reads == 1 {
                await withCheckedContinuation { continuation = $0 }
                throw FeatureRPC.Failure.unavailable
            }
            if failures > 0 { failures -= 1; throw FeatureRPC.Failure.busy }
        } else { otherMethods.append(method) }
        let call = try JSONDecoder().decode(FeatureAskCall.self, from: payload)
        return try await FeatureAskCache.handle(method, payload: call.payload, api: base)
    }
    func waitForRead() async throws {
        for _ in 0..<1000 {
            if reads > 0 { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ModuleFailure.unavailable
    }
    func release() { continuation?.resume(); continuation = nil }
}
