@testable import Typeflux
import XCTest

final class LocalModelTranscriberTests: XCTestCase {
    func testSenseVoiceTranscriberReportsUnavailableNativeRuntime() async {
        let transcriber = SenseVoiceTranscriber(
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            modelFolder: "/tmp/sensevoice"
        )
        let audioFile = AudioFile(fileURL: URL(fileURLWithPath: "/tmp/test.wav"), duration: 1.0)

        do {
            _ = try await transcriber.transcribe(audioFile: audioFile)
            XCTFail("Expected SenseVoiceTranscriber to throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                L(
                    "localSTT.error.runtimeUnavailable",
                    LocalSTTModel.senseVoiceSmall.displayName
                )
            )
        }
    }

    func testQwen3ASRTranscriberReportsUnavailableNativeRuntime() async {
        let transcriber = Qwen3ASRTranscriber(
            modelIdentifier: LocalSTTModel.qwen3ASR.defaultModelIdentifier,
            modelFolder: "/tmp/qwen3-asr"
        )
        let audioFile = AudioFile(fileURL: URL(fileURLWithPath: "/tmp/test.wav"), duration: 1.0)

        do {
            _ = try await transcriber.transcribe(audioFile: audioFile)
            XCTFail("Expected Qwen3ASRTranscriber to throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                L(
                    "localSTT.error.runtimeUnavailable",
                    LocalSTTModel.qwen3ASR.displayName
                )
            )
        }
    }
}
