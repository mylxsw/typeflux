import Darwin
import Foundation
import TypefluxInferenceProtocol
import TypefluxInferenceRuntime
import XCTest

final class InferenceProtocolTests: XCTestCase {
    func testRejectsInvalidVersionsSizesPathsAndOperations() throws {
        var message = InferenceMessage(kind: .prepare)
        XCTAssertThrowsError(try message.validate())
        message.configuration = .init(model: "small", modelFolder: "/model")
        try message.validate()
        message.version = 2
        XCTAssertThrowsError(try message.validate())
        message.version = 1; message.sequence = -1
        XCTAssertThrowsError(try message.validate())
        message.sequence = 0; message.language = "private-language"
        XCTAssertThrowsError(try message.validate())
        message.language = nil; message.prompt = String(repeating: "x", count: 16385)
        XCTAssertThrowsError(try message.validate())
        for configuration in [InferenceConfiguration(model: ""), .init(model: "small", modelFolder: "relative"),
                              .init(model: "small", repository: "secret\0") ] {
            XCTAssertThrowsError(try configuration.validate())
        }
        message = .init(kind: .transcribe)
        XCTAssertThrowsError(try message.validate())
        message.audioPath = "/audio"; try message.validate()
        message.kind = .final
        XCTAssertThrowsError(try message.validate())
        XCTAssertFalse(InferenceFailure.engineFailed.localizedDescription.contains("secret"))
    }

    func testFramesRoundTripAndMailboxCoalesces() throws {
        let (left, right) = try inferenceSocketPair()
        defer { left.stop(); right.stop() }
        var message = InferenceMessage(kind: .final)
        message.text = "你好 world"
        try left.send(message, deadline: .now.advanced(by: .seconds(1)))
        let decoded = try right.receive(deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.text, message.text)
        message.text = String(repeating: "\u{1}", count: 131072)
        XCTAssertThrowsError(try left.send(message, deadline: .now.advanced(by: .seconds(1))))
        let mailbox = InferenceProgressMailbox()
        for i in 0..<10000 { mailbox.offer("\(i)") }
        mailbox.offer("")
        mailbox.offer(String(repeating: "x", count: 131073))
        XCTAssertEqual(mailbox.take(), "9999")
        XCTAssertNil(mailbox.take())
    }

    func testMalformedOversizedTruncatedAndStalledFramesFailBoundedly() throws {
        for bytes in [Data([0, 5, 0, 0]), Data([0, 0, 0, 0]), Data([0, 0, 0, 1, 123]), Data([0, 0])] {
            let (left, right) = try inferenceSocketPair()
            bytes.withUnsafeBytes { _ = Darwin.write(left.descriptor, $0.baseAddress, $0.count) }
            XCTAssertThrowsError(try right.receive(deadline: .now.advanced(by: .milliseconds(30))))
            left.stop(); right.stop()
        }
        let (left, right) = try inferenceSocketPair()
        left.stop()
        XCTAssertThrowsError(try right.receive(deadline: .now.advanced(by: .seconds(1))))
        right.stop(); right.stop()
        XCTAssertThrowsError(try right.send(.init(kind: .probe), deadline: .now.advanced(by: .seconds(1))))
        XCTAssertThrowsError(try InferenceSocket(owning: -1))
    }

    func testBackpressureHasAnAbsoluteDeadline() throws {
        let (left, right) = try inferenceSocketPair()
        defer { left.stop(); right.stop() }
        var message = InferenceMessage(kind: .final)
        message.text = String(repeating: "x", count: 131072)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(60))
        XCTAssertThrowsError(try { for _ in 0..<100 { try left.send(message, deadline: deadline) } }())
    }

    func testServerKeepsOneEngineAndDeliversFinalAfterCoalescedProgress() async throws {
        let (left, right) = try inferenceSocketPair()
        let engine = InferenceFixtureEngine()
        let task = Task.detached { await InferenceServer(engine: engine).serve(socket: right) }
        var prepare = InferenceMessage(kind: .prepare)
        prepare.configuration = .init(model: "fixture", modelFolder: "/fixture")
        try left.send(prepare, deadline: .now.advanced(by: .seconds(1)))
        let ready = try left.receive(deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(ready.modelPath, "/fixture")
        for _ in 0..<2 {
            var request = InferenceMessage(kind: .transcribe)
            request.audioPath = "/fixture.wav"
            try left.send(request, deadline: .now.advanced(by: .seconds(1)))
            var sequence = 1, partials = 0
            while true {
                let reply = try left.receive(deadline: .now.advanced(by: .seconds(2)))
                XCTAssertEqual(reply.id, request.id)
                XCTAssertEqual(reply.sequence, sequence)
                sequence += 1
                if reply.kind == .final { XCTAssertEqual(reply.text, "final"); break }
                XCTAssertEqual(reply.kind, .progress); partials += 1
            }
            XCTAssertGreaterThan(partials, 0)
            XCTAssertLessThan(partials, 5)
        }
        XCTAssertEqual(engine.prepares, 1)
        left.stop(); await task.value
    }

    func testServerRejectsUnpreparedDuplicateAndResponseMessages() async throws {
        for kind in [InferenceMessage.Kind.transcribe, .final, .prepare] {
            let (left, right) = try inferenceSocketPair()
            let task = Task.detached { await InferenceServer(engine: InferenceFixtureEngine()).serve(socket: right) }
            var message = InferenceMessage(kind: kind)
            message.audioPath = "/fixture"; message.text = "unexpected"
            message.configuration = .init(model: "fixture")
            if kind == .prepare {
                try left.send(message, deadline: .now.advanced(by: .seconds(1)))
                _ = try left.receive(deadline: .now.advanced(by: .seconds(1)))
            }
            try left.send(message, deadline: .now.advanced(by: .seconds(1)))
            XCTAssertThrowsError(try left.receive(deadline: .now.advanced(by: .seconds(1))))
            left.stop(); await task.value
        }
    }

    func testEngineFailureIsRedactedAndClosesTheSession() async throws {
        let (left, right) = try inferenceSocketPair()
        let engine = InferenceFixtureEngine(fail: true)
        let task = Task.detached { await InferenceServer(engine: engine).serve(socket: right) }
        var message = InferenceMessage(kind: .prepare)
        message.configuration = .init(model: "fixture")
        try left.send(message, deadline: .now.advanced(by: .seconds(1)))
        _ = try left.receive(deadline: .now.advanced(by: .seconds(1)))
        message = .init(kind: .transcribe); message.audioPath = "/fixture"
        try left.send(message, deadline: .now.advanced(by: .seconds(1)))
        let failure = try left.receive(deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(failure.kind, .failed)
        XCTAssertNil(failure.text)
        await task.value; left.stop()
        let realEngine = WhisperInferenceEngine()
        do { _ = try await realEngine.transcribe(message) { _ in true }; XCTFail() } catch {}
        do { _ = try await realEngine.prepare(.init(model: "")); XCTFail() } catch {}
    }
}

func inferenceSocketPair() throws -> (InferenceSocket, InferenceSocket) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw InferenceFailure.unavailable }
    return try (InferenceSocket(owning: pair[0]), InferenceSocket(owning: pair[1]))
}

final class InferenceFixtureEngine: InferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var request: InferenceMessage?
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    var prepares: Int { lock.withLock { count } }
    var lastRequest: InferenceMessage? { lock.withLock { request } }
    func prepare(_ configuration: InferenceConfiguration) async throws -> String? {
        lock.withLock { count += 1 }
        return configuration.modelFolder
    }
    func transcribe(_ request: InferenceMessage, progress: @escaping @Sendable (String) -> Bool) async throws -> String {
        lock.withLock { self.request = request }
        if fail { throw NSError(domain: "secret audio path and prompt", code: 1) }
        for i in 0..<1000 { _ = progress("partial \(i)") }
        try await Task.sleep(for: .milliseconds(230))
        return "final"
    }
}
