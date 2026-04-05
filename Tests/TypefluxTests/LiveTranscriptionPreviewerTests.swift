import AVFoundation
@testable import Typeflux
import XCTest

final class LiveTranscriptionPreviewerTests: XCTestCase {
    func testPrepareForStartPreservesPendingBuffersUntilBackendStarts() async throws {
        let settingsStore = SettingsStore()
        settingsStore.whisperBaseURL = ""
        settingsStore.whisperModel = "whisper-1"

        let backend = MockLivePreviewBackend()
        let previewer = LiveTranscriptionPreviewer(
            settingsStore: settingsStore,
            openAIBackendFactory: { backend },
            appleBackendFactory: { backend },
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

    private func makeTestBuffer(sampleCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false,
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

    func start(onTextUpdate _: @escaping @Sendable (String) -> Void) async throws {}

    func append(_ buffer: AVAudioPCMBuffer) async {
        appendedFrameCounts.append(buffer.frameLength)
    }

    func finish() async -> String {
        ""
    }

    func cancel() async {}
}
