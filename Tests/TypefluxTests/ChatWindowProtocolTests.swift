import Darwin
import Foundation
import Testing
import TypefluxChatWindowProtocol

@Suite(.serialized)
struct ChatWindowProtocolTests {
    @Test func snapshotAndEnvelopeRejectOversizedOrAmbiguousPayloads() throws {
        let generation = UUID()
        try ChatWindowSnapshot(sequence: 1, title: "Chat", messages: []).validate()
        for snapshot in [
            ChatWindowSnapshot(sequence: 0, title: "Chat", messages: []),
            .init(sequence: 1, title: String(repeating: "a", count: 513), messages: []),
            .init(sequence: 1, title: "Chat", messages: Array(repeating: .init(role: .user, text: "a"), count: 513)),
            .init(sequence: 1, title: "Chat", messages: [.init(role: .user, text: String(repeating: "a", count: 65537))]),
            .init(sequence: 1, title: "Chat", messages: Array(repeating: .init(role: .user, text: String(repeating: "a", count: 65536)), count: 5))
        ] { #expect(throws: ChatWindowFailure.invalidProtocol) { try snapshot.validate() } }
        var message = ChatWindowEnvelope(generation: generation, kind: .hello)
        message.version = 2
        #expect(throws: ChatWindowFailure.invalidProtocol) { try message.validate() }
        message.version = 1; message.snapshot = .init(sequence: 1, title: "Chat", messages: [])
        #expect(throws: ChatWindowFailure.invalidProtocol) { try message.validate() }
        message.snapshot = nil; message.kind = .present
        #expect(throws: ChatWindowFailure.invalidProtocol) { try message.validate() }
        message.kind = .pong; message.sequence = 1
        #expect(throws: ChatWindowFailure.invalidProtocol) { try message.validate() }
        message.kind = .acknowledged; message.sequence = 0
        #expect(throws: ChatWindowFailure.invalidProtocol) { try message.validate() }
    }

    @Test func sessionRequiresHandshakeAndFencesGenerationAndSequence() throws {
        let generation = UUID()
        var session = ChatWindowSession()
        #expect(throws: ChatWindowFailure.invalidProtocol) { try session.accept(.init(generation: generation, kind: .ping)) }
        let hello = ChatWindowEnvelope(generation: generation, kind: .hello)
        let ready = try session.accept(hello)
        #expect(ready.kind == .ready && ready.id == hello.id)
        #expect(throws: ChatWindowFailure.invalidProtocol) { try session.accept(hello) }
        #expect(throws: ChatWindowFailure.invalidProtocol) { try session.accept(.init(generation: UUID(), kind: .ping)) }
        let present = ChatWindowEnvelope(generation: generation, kind: .present, snapshot: .init(sequence: 2, title: "Chat", messages: []))
        #expect(try session.accept(present).sequence == 2)
        #expect(throws: ChatWindowFailure.invalidProtocol) { try session.accept(present) }
        #expect(try session.accept(.init(generation: generation, kind: .ping)).kind == .pong)
        #expect(try session.accept(.init(generation: generation, kind: .hide)).kind == .acknowledged)
        #expect(throws: ChatWindowFailure.invalidProtocol) { try session.accept(.init(generation: generation, kind: .ready)) }
        _ = try session.accept(.init(generation: generation, kind: .shutdown))
        #expect(session.stopped)
        #expect(throws: ChatWindowFailure.unavailable) { try session.accept(hello) }
    }

    @Test func framedSocketBoundsInputAndWakesOnStop() async throws {
        let (left, right) = try chatWindowSocketPair()
        let message = ChatWindowEnvelope(generation: UUID(), kind: .hello)
        try left.send(message, deadline: .now.advanced(by: .seconds(1)))
        #expect(try right.receive(deadline: .now.advanced(by: .seconds(1))) == message)
        #expect(throws: ChatWindowFailure.timedOut) { try right.receive(deadline: .now.advanced(by: .milliseconds(10))) }
        let waiting = Task.detached { try right.receive(deadline: .now.advanced(by: .seconds(2))) }
        right.stop(); right.stop()
        await #expect(throws: ChatWindowFailure.self) { try await waiting.value }
        #expect(right.isStopped)
        #expect(throws: ChatWindowFailure.self) { try left.receive(deadline: .now.advanced(by: .seconds(1))) }
    }

    @Test func malformedFramesCannotAllocateUnboundedMemory() throws {
        for bytes in [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 1, 123])] {
            let (left, right) = try chatWindowSocketPair()
            _ = bytes.withUnsafeBytes { Darwin.write(left.descriptor, $0.baseAddress!, $0.count) }
            #expect(throws: ChatWindowFailure.invalidProtocol) { try right.receive(deadline: .now.advanced(by: .seconds(1))) }
        }
        let (left, _) = try chatWindowSocketPair()
        let expanded = ChatWindowSnapshot(sequence: 1, title: "Escaped", messages: Array(repeating: .init(role: .user, text: String(repeating: "\0", count: 65536)), count: 4))
        #expect(throws: ChatWindowFailure.invalidProtocol) { try left.send(.init(generation: UUID(), kind: .present, snapshot: expanded), deadline: .now.advanced(by: .seconds(1))) }
        #expect(throws: ChatWindowFailure.unavailable) { try ChatWindowSocket(owning: -1) }
    }
}

func chatWindowSocketPair() throws -> (ChatWindowSocket, ChatWindowSocket) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ChatWindowFailure.unavailable }
    return try (ChatWindowSocket(owning: pair[0]), ChatWindowSocket(owning: pair[1]))
}
