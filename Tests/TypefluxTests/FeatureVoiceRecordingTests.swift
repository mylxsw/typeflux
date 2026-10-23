import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureVoiceRecordingTests {
    @Test func `editor recording completes through the single owner and rejects another editor`() async throws {
        let recorder = ConsolidatedVoiceFixture()
        let service = FeatureVoiceOwner(makeRecorder: { recorder })
        var calls: [String] = []
        let client = FeatureVoiceRecording(owner: .chat, route: { command, _ in
            calls.append(command.action)
            return try await service.handle(command)
        })
        var level: Float?, text: String?
        client.observe(level: { level = $0 }, transcript: { value, _ in text = value })
        client.handleHotkey(.prepare(auxiliary: true, locked: false))
        try await client.start()
        #expect(service.editorOwner == .chat)
        #expect(client.audioStartedAt == 42)
        let other = FeatureVoiceRequest(session: UUID(), owner: .host, event: .prepare(auxiliary: false, locked: true))
        await #expect(throws: FeatureRPC.Failure.busy) {
            try await service.handle(.init(
                destination: .voice,
                action: "voice.prepare",
                payload: JSONEncoder().encode(other)
            ))
        }
        client.handleHotkey(.lock)
        client.handleHotkey(.release(43))
        await Task.yield()
        #expect(try await client.transcribe() == "fixture speech")
        #expect(service.editorOwner == nil)
        #expect(calls.contains("voice.event"))
        #expect(recorder.starts == 1 && recorder.finishes == 1)
        #expect(level == nil && text == nil)
        await client.cancel()
        #expect(recorder.cancels == 0)
    }

    @Test func `cancelled editor cannot receive A former sessions result`() async throws {
        let recorder = ConsolidatedVoiceFixture()
        let service = FeatureVoiceOwner(makeRecorder: { recorder })
        var session: UUID?
        let client = FeatureVoiceRecording(owner: .host, route: { command, _ in
            session = try JSONDecoder().decode(FeatureVoiceRequest.self, from: command.payload).session
            return try await service.handle(command)
        })
        var level: Float = 0, transcript = ""
        client.observe(level: { level = $0 }, transcript: { value, _ in transcript = value })
        client.handleHotkey(.prepare(auxiliary: false, locked: true))
        client.handleHotkey(.release(3))
        try await client.start()
        let id = try #require(session)
        FeatureVoiceRecording.receive(.init(session: id, level: 0.5))
        FeatureVoiceRecording.receive(.init(session: id, text: "partial"))
        #expect(level == 0.5 && transcript == "partial")
        await client.cancel()
        FeatureVoiceRecording.receive(.init(session: id, level: 1, text: "late", final: true))
        #expect(level == 0.5 && transcript == "partial")
        #expect(recorder.cancels == 1 && service.editorOwner == nil)
        await #expect(throws: CancellationError.self) { try await client.start() }
    }

    @Test func `failed start releases the owner and stale commands cannot stop the new session`() async throws {
        let recorder = ConsolidatedVoiceFixture()
        recorder.failStart = true
        let service = FeatureVoiceOwner(makeRecorder: { recorder })
        let first = FeatureVoiceRequest(session: UUID(), owner: .chat, event: .prepare(auxiliary: false, locked: true))
        func command(_ action: String, _ request: FeatureVoiceRequest) throws -> FeatureCommand {
            try .init(destination: .voice, action: action, payload: JSONEncoder().encode(request))
        }
        _ = try await service.handle(command("voice.prepare", first))
        await #expect(throws: CancellationError.self) { try await service.handle(command("voice.start", first)) }
        #expect(service.editorOwner == nil)
        recorder.failStart = false
        let next = FeatureVoiceRequest(session: UUID(), owner: .host, event: .prepare(auxiliary: false, locked: true))
        _ = try await service.handle(command("voice.prepare", next))
        _ = try await service.handle(command("voice.cancel", first))
        #expect(service.editorOwner == .host)
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await service.handle(command("voice.start", first))
        }
        await service.cancel()
        #expect(service.editorOwner == nil)
    }

    @Test func `unknown owners and commands are rejected`() async throws {
        let service = FeatureVoiceOwner(makeRecorder: { ConsolidatedVoiceFixture() })
        let request = FeatureVoiceRequest(session: UUID(), owner: .screenshot)
        await #expect(throws: FeatureRPC.Failure.invalidMessage) {
            try await service.handle(.init(
                destination: .voice,
                action: "voice.prepare",
                payload: JSONEncoder().encode(request)
            ))
        }
        let client = FeatureVoiceRecording(owner: .host, route: { _, _ in throw FeatureRPC.Failure.unavailable })
        await #expect(throws: CancellationError.self) { try await client.start() }
    }
}

@MainActor
private final class ConsolidatedVoiceFixture: AskVoiceRecording {
    var starts = 0, finishes = 0, cancels = 0
    var failStart = false
    var onTranscribing: (() -> Void)?
    var audioStartedAt: TimeInterval? {
        42
    }

    func start() async throws {
        starts += 1; if failStart {
            throw CancellationError()
        }
    }

    func transcribe() async throws -> String {
        finishes += 1; onTranscribing?(); return "fixture speech"
    }

    func cancel() async {
        cancels += 1
    }
}


extension FeatureVoiceRecordingTests {
    @Test func indexingStaysPausedThroughEditorRecognitionAndRewrite() async throws {
        let recorder = ConsolidatedVoiceFixture()
        var activity: [Bool] = []
        let owner = FeatureVoiceOwner(makeRecorder: { recorder }, activity: { activity.append($0) })
        let request = FeatureVoiceRequest(session: UUID(), owner: .host, event: .prepare(auxiliary: false, locked: true))
        func command(_ action: String) throws -> FeatureCommand {
            .init(destination: .voice, action: action, payload: try JSONEncoder().encode(request))
        }
        _ = try await owner.handle(command("voice.prepare"))
        _ = try await owner.handle(command("voice.start"))
        #expect(activity == [true])
        var recognized = false
        recorder.onTranscribing = { recognized = true; #expect(activity.last == true) }
        _ = try await owner.handle(command("voice.transcribe"))
        #expect(recognized && activity == [true, false])
        #expect(owner.editorOwner == nil)
    }

    @Test func presentationRecorderCannotOpenAMicrophone() throws {
        let recorder = FeatureAudioRecorder()
        #expect(throws: FeatureRPC.Failure.unavailable) { try recorder.start(levelHandler: { _ in }) }
        #expect(throws: FeatureRPC.Failure.unavailable) { try recorder.stop() }
        let press = FeatureWorkflowPress(asksSelection: true, locked: false, detectedAt: Date(), uptime: 42, auxiliary: true)
        let decoded = try JSONDecoder().decode(FeatureWorkflowPress.self, from: JSONEncoder().encode(press))
        #expect(decoded.asksSelection && !decoded.locked && decoded.auxiliary && decoded.uptime == 42)
    }
}


extension FeatureVoiceRecordingTests {
    @Test func audioStartTimeArrivesBeforeTheRecognizerConnectionCompletes() async throws {
        var request: FeatureVoiceRequest?
        var connected: CheckedContinuation<Void, Never>?
        let client = FeatureVoiceRecording(owner: .host, route: { command, _ in
            request = try JSONDecoder().decode(FeatureVoiceRequest.self, from: command.payload)
            if command.action == "voice.start" {
                await withCheckedContinuation { connected = $0 }
                return try JSONEncoder().encode(Optional<TimeInterval>(7))
            }
            return Data()
        })
        client.handleHotkey(.prepare(auxiliary: false, locked: false))
        let start = Task { try await client.start() }
        for _ in 0..<100 where connected == nil { try await Task.sleep(for: .milliseconds(2)) }
        let id = try #require(request?.session)
        FeatureVoiceRecording.receive(.init(session: id, audioStartedAt: 7))
        #expect(client.audioStartedAt == 7, "A held shortcut must not become locked merely because ASR is still connecting")
        connected?.resume()
        try await start.value
        await client.cancel()
        client.handleHotkey(.prepare(auxiliary: false, locked: false))
        #expect(client.audioStartedAt == nil)
        await client.cancel()
    }
}
