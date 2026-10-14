import AVFoundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenRecordingDevicePreviewTests {
    @Test func `preview configuration and shutdown drain without opening real devices`() async {
        let preview = ScreenRecordingDevicePreview(input: { _ in nil }, authorization: { _ in .authorized })
        await preview.configure(camera: true, microphone: true)
        await preview.configure(camera: true, microphone: true)
        #expect(preview.session.inputs.isEmpty)
        #expect(!preview.session.isRunning)
        #expect(preview.level == 0)
        await preview.stop()
        #expect(preview.session.outputs.isEmpty)
    }

    @Test func `microphone meter reads PCM samples and ignores video buffers`() async throws {
        let sample = try ScreenRecordingMediaTests.audioSample(at: 100)
        let meter = ScreenRecordingAudioMeter()
        meter.update(sample)
        #expect(meter.level > 0.19 && meter.level < 0.21)
        #expect(try ScreenRecordingAudioMeter.amplitude(ScreenRecordingMediaTests.videoSample(at: 100)) == 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ScreenRecordingWriter(
            url: url,
            size: CGSize(width: 160, height: 120),
            options: ScreenRecordingOptions()
        )
        let capture = ScreenRecordingCapture(writer: writer, options: ScreenRecordingOptions(), onError: { _ in })
        capture.receiveDeviceSample(sample, video: false)
        #expect(capture.audioLevel > 0.19)
        await capture.stop()
        await writer.cancel()
    }
}
