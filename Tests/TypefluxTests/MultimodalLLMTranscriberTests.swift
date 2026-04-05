@testable import Typeflux
import XCTest

final class MultimodalLLMTranscriberTests: XCTestCase {
    func testMakeUserMessageContentIncludesAudioAndInstructionText() {
        let content = MultimodalLLMTranscriber.makeUserMessageContent(
            base64Audio: "base64-audio",
            audioFormat: "wav",
        )

        XCTAssertEqual(content.count, 2)

        let audioContent = content[0]
        let inputAudio = audioContent["input_audio"] as? [String: String]
        XCTAssertEqual(audioContent["type"] as? String, "input_audio")
        XCTAssertEqual(inputAudio?["data"], "base64-audio")
        XCTAssertEqual(inputAudio?["format"], "wav")

        let textContent = content[1]
        XCTAssertEqual(textContent["type"] as? String, "text")
        XCTAssertEqual(
            textContent["text"] as? String,
            MultimodalLLMTranscriber.audioProcessingInstructionText,
        )
    }
}
