import XCTest
@testable import VoiceInput

final class OpenAIRealtimeTranscriptAccumulatorTests: XCTestCase {
    func testAccumulatorBuildsTranscriptAcrossDeltaAndCompletedEvents() throws {
        var accumulator = OpenAIRealtimeTranscriptAccumulator()

        let committed = try XCTUnwrap(
            """
            {"type":"input_audio_buffer.committed","item_id":"item-1"}
            """.data(using: .utf8)
        )
        let delta1 = try XCTUnwrap(
            """
            {"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"hello "}
            """.data(using: .utf8)
        )
        let delta2 = try XCTUnwrap(
            """
            {"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"world"}
            """.data(using: .utf8)
        )
        let completed = try XCTUnwrap(
            """
            {"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"hello world"}
            """.data(using: .utf8)
        )

        XCTAssertNil(try accumulator.process(eventData: committed))
        XCTAssertEqual(try accumulator.process(eventData: delta1)?.text, "hello")
        XCTAssertEqual(try accumulator.process(eventData: delta2)?.text, "hello world")
        XCTAssertEqual(try accumulator.process(eventData: completed)?.text, "hello world")
        XCTAssertEqual(accumulator.finalText(), "hello world")
    }

    func testAccumulatorPreservesCommittedOrder() throws {
        var accumulator = OpenAIRealtimeTranscriptAccumulator()

        let firstCommit = try XCTUnwrap(
            """
            {"type":"input_audio_buffer.committed","item_id":"first"}
            """.data(using: .utf8)
        )
        let secondCommit = try XCTUnwrap(
            """
            {"type":"input_audio_buffer.committed","item_id":"second","previous_item_id":"first"}
            """.data(using: .utf8)
        )
        let firstComplete = try XCTUnwrap(
            """
            {"type":"conversation.item.input_audio_transcription.completed","item_id":"first","transcript":"one"}
            """.data(using: .utf8)
        )
        let secondComplete = try XCTUnwrap(
            """
            {"type":"conversation.item.input_audio_transcription.completed","item_id":"second","transcript":"two"}
            """.data(using: .utf8)
        )

        _ = try accumulator.process(eventData: firstCommit)
        _ = try accumulator.process(eventData: secondCommit)
        _ = try accumulator.process(eventData: firstComplete)
        _ = try accumulator.process(eventData: secondComplete)

        XCTAssertEqual(accumulator.finalText(), "one\ntwo")
    }
}
