import AVFoundation
@testable import Typeflux
import XCTest

final class LiveTranscriptionPreviewerTests: XCTestCase {
    func testStartUsesLocalBackendForLocalModelProvider() async throws {
        let settingsStore = SettingsStore()
        settingsStore.sttProvider = .localModel

        let localBackend = MockLivePreviewBackend()
        let openAIBackend = MockLivePreviewBackend()
        let appleBackend = MockLivePreviewBackend()
        let previewer = LiveTranscriptionPreviewer(
            settingsStore: settingsStore,
            localBackendFactory: { localBackend },
            openAIBackendFactory: { openAIBackend },
            appleBackendFactory: { appleBackend }
        )

        try await previewer.start(onTextUpdate: { _ in })

        let localStartCount = await localBackend.startCount()
        let openAIStartCount = await openAIBackend.startCount()
        let appleStartCount = await appleBackend.startCount()
        XCTAssertEqual(localStartCount, 1)
        XCTAssertEqual(openAIStartCount, 0)
        XCTAssertEqual(appleStartCount, 0)
    }

    func testStartDoesNotUseLocalBackendForTypefluxCloudWhenLocalOptimizationIsEnabled() async throws {
        let settingsStore = SettingsStore()
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.localOptimizationEnabled = true

        let localBackend = MockLivePreviewBackend()
        let openAIBackend = MockLivePreviewBackend()
        let appleBackend = MockLivePreviewBackend()
        let previewer = LiveTranscriptionPreviewer(
            settingsStore: settingsStore,
            localBackendFactory: { localBackend },
            openAIBackendFactory: { openAIBackend },
            appleBackendFactory: { appleBackend }
        )

        try await previewer.start(onTextUpdate: { _ in })

        let localStartCount = await localBackend.startCount()
        let openAIStartCount = await openAIBackend.startCount()
        let appleStartCount = await appleBackend.startCount()
        XCTAssertEqual(localStartCount, 0)
        XCTAssertEqual(openAIStartCount + appleStartCount, 1)
    }

    func testUnpaidThirdPartyProviderDoesNotUseLocalBackend() async throws {
        let settingsStore = SettingsStore()
        settingsStore.sttProvider = .whisperAPI

        let localBackend = MockLivePreviewBackend()
        let openAIBackend = MockLivePreviewBackend()
        let appleBackend = MockLivePreviewBackend()
        let previewer = LiveTranscriptionPreviewer(
            settingsStore: settingsStore,
            localBackendFactory: { localBackend },
            openAIBackendFactory: { openAIBackend },
            appleBackendFactory: { appleBackend },
            canUseCloudASR: { false }
        )

        try await previewer.start(onTextUpdate: { _ in })

        let localStartCount = await localBackend.startCount()
        let openAIStartCount = await openAIBackend.startCount()
        let appleStartCount = await appleBackend.startCount()
        XCTAssertEqual(localStartCount, 0)
        XCTAssertEqual(openAIStartCount + appleStartCount, 1)
    }

    func testPrepareForStartPreservesPendingBuffersUntilBackendStarts() async throws {
        let settingsStore = SettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.localOptimizationEnabled = false
        settingsStore.whisperBaseURL = ""
        settingsStore.whisperModel = "whisper-1"

        let backend = MockLivePreviewBackend()
        let previewer = LiveTranscriptionPreviewer(
            settingsStore: settingsStore,
            openAIBackendFactory: { backend },
            appleBackendFactory: { backend }
        )

        let buffer = try makeTestBuffer(sampleCount: 4)

        await previewer.prepareForStart()
        await previewer.append(buffer)
        try await previewer.start(onTextUpdate: { _ in })

        let appendedCount = await backend.appendedFrameCounts.count
        let firstFrameCount = await backend.appendedFrameCounts.first
        XCTAssertEqual(appendedCount, 1)
        XCTAssertEqual(firstFrameCount, 4)
    }

    func testLocalModelBackendTranscribesChunkAfterEnoughAudio() async throws {
        let transcriber = MockLivePreviewTranscriber(result: "hello")
        let backend = LocalModelLivePreviewBackend {
            transcriber
        }
        let updateReceived = expectation(description: "live preview update received")

        try await backend.start { text in
            XCTAssertEqual(text, "hello")
            updateReceived.fulfill()
        }

        let buffer = try makeTestBuffer(sampleCount: 40000)
        await backend.append(buffer)

        await fulfillment(of: [updateReceived], timeout: 1.0)
        let transcribeCallCount = await transcriber.transcribeCallCount()
        XCTAssertEqual(transcribeCallCount, 1)
        _ = await backend.finish()
    }

    private func makeTestBuffer(sampleCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw XCTSkip("Unable to create audio format")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount) else {
            throw XCTSkip("Unable to allocate audio buffer")
        }

        buffer.frameLength = sampleCount
        if let channel = buffer.floatChannelData?[0] {
            for index in 0 ..< Int(sampleCount) {
                channel[index] = Float(index) / 10
            }
        }
        return buffer
    }
}

actor MockLivePreviewBackend: LivePreviewBackend {
    private(set) var appendedFrameCounts: [AVAudioFrameCount] = []
    private(set) var startCallCount = 0

    func start(onTextUpdate _: @escaping @Sendable (String) -> Void) async throws {
        startCallCount += 1
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        appendedFrameCounts.append(buffer.frameLength)
    }

    func finish() async -> String {
        ""
    }

    func cancel() async {}

    func startCount() -> Int {
        startCallCount
    }
}

private actor MockLivePreviewTranscriber: Transcriber {
    private let result: String
    private var calls = 0

    init(result: String) {
        self.result = result
    }

    func transcribe(audioFile _: AudioFile) async throws -> String {
        calls += 1
        return result
    }

    func transcribeCallCount() -> Int {
        calls
    }
}
