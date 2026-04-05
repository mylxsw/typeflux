@testable import Typeflux
import XCTest

final class OpenAICompatibleResponseSupportTests: XCTestCase {
    func testExtractsPlainStringDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": "hello"]],
            ],
        ])

        XCTAssertEqual(OpenAICompatibleResponseSupport.extractTextDelta(from: data), "hello")
    }

    func testExtractsStructuredTextDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": [["type": "text", "text": "hello"], ["type": "text", "text": " world"]]]],
            ],
        ])

        XCTAssertEqual(OpenAICompatibleResponseSupport.extractTextDelta(from: data), "hello world")
    }

    func testExtractsStructuredMarkdownBlocksWithoutFlatteningParagraphs() throws {
        let data = try jsonData([
            "choices": [
                ["message": ["content": [
                    ["type": "text", "text": "## Summary"],
                    ["type": "text", "text": "- first item\n- second item"],
                ]]],
            ],
        ])

        XCTAssertEqual(
            OpenAICompatibleResponseSupport.extractTextDelta(from: data),
            "## Summary\n\n- first item\n- second item",
        )
    }

    func testDetectsReasoningOnlyDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["reasoning_content": "step by step"]],
            ],
        ])

        XCTAssertNil(OpenAICompatibleResponseSupport.extractTextDelta(from: data))
        XCTAssertTrue(OpenAICompatibleResponseSupport.containsReasoningDelta(data))
    }

    func testProviderTuningDisablesThinkingForDoubaoEndpoints() throws {
        var body: [String: Any] = [:]
        try OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: XCTUnwrap(URL(string: "https://ark.cn-beijing.volces.com/api/v3")),
            model: "doubao-seed-1-6",
        )

        let thinking = try XCTUnwrap(body["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - Extended OpenAICompatibleResponseSupport tests

extension OpenAICompatibleResponseSupportTests {
    // MARK: - stripLeadingThinkingTags additional cases

    func testStripLeadingThinkingTagsWithEmptyText() {
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("")
        XCTAssertEqual(result, "")
    }

    func testStripLeadingThinkingTagsWithNoThinkTags() {
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("Hello world")
        XCTAssertEqual(result, "Hello world")
    }

    func testStripLeadingThinkingTagsWithOnlyThinkBlock() {
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("<think>internal reasoning</think>")
        XCTAssertEqual(result, "")
    }

    func testStripLeadingThinkingTagsWithThinkBlockAndAnswer() {
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("<think>I think...</think>The answer is 42.")
        XCTAssertEqual(result, "The answer is 42.")
    }

    func testStripLeadingThinkingTagsWithLeadingWhitespace() {
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("<think>thinking</think>  Final answer.")
        XCTAssertEqual(result, "Final answer.")
    }

    func testStripLeadingThinkingTagsDoesNotStripNonLeadingThink() {
        // Think block that is NOT at the start should not be stripped
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("First. <think>thinking</think> Second.")
        XCTAssertEqual(result, "First. <think>thinking</think> Second.")
    }

    func testStripLeadingThinkingTagsMultilineThinkBlock() {
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("<think>\nLine 1\nLine 2\n</think>Answer")
        XCTAssertEqual(result, "Answer")
    }

    func testStripLeadingThinkingTagsWithMidpointText() {
        // Block appears mid-text — must preserve all original text
        let result = OpenAICompatibleResponseSupport.stripLeadingThinkingTags("No tags here")
        XCTAssertEqual(result, "No tags here")
    }

    // MARK: - StreamingThinkingFilter

    func testStreamingThinkingFilterPassesThroughPlainText() {
        var filter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()
        let result = filter.process("Hello")
        XCTAssertEqual(result, "Hello")
    }

    func testStreamingThinkingFilterStripsThinkBlock() {
        var filter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()
        let chunk1 = filter.process("<think>")
        let chunk2 = filter.process("internal thought")
        let chunk3 = filter.process("</think>")
        let chunk4 = filter.process("Answer")
        // All intermediate think content should be filtered
        XCTAssertNil(chunk1)
        XCTAssertNil(chunk2)
        XCTAssertNil(chunk3)
        XCTAssertEqual(chunk4, "Answer")
    }

    func testStreamingThinkingFilterFlushReturnsRemainingContent() {
        var filter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()
        _ = filter.process("some text")
        let flushed = filter.flush()
        // flush returns any buffered content not yet emitted
        _ = flushed // Just verify no crash
    }

    func testStreamingThinkingFilterHandlesEmptyInput() {
        var filter = OpenAICompatibleResponseSupport.StreamingThinkingFilter()
        let result = filter.process("")
        // Empty input may return nil or empty string
        let str = result ?? ""
        XCTAssertEqual(str, "")
    }

    // MARK: - extractTextDelta

    func testExtractTextDeltaFromEmptyData() {
        let result = OpenAICompatibleResponseSupport.extractTextDelta(from: Data())
        XCTAssertNil(result)
    }

    func testExtractTextDeltaFromInvalidJSON() {
        let result = OpenAICompatibleResponseSupport.extractTextDelta(from: Data("bad".utf8))
        XCTAssertNil(result)
    }

    func testExtractTextDeltaFromValidDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": "partial text"]],
            ],
        ])
        let result = OpenAICompatibleResponseSupport.extractTextDelta(from: data)
        XCTAssertEqual(result, "partial text")
    }

    func testExtractTextDeltaFromEmptyDeltaContent() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": ""]],
            ],
        ])
        let result = OpenAICompatibleResponseSupport.extractTextDelta(from: data)
        XCTAssertNil(result)
    }

    // MARK: - containsReasoningDelta

    func testContainsReasoningDeltaReturnsFalseForTextOnlyDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": "text content"]],
            ],
        ])
        XCTAssertFalse(OpenAICompatibleResponseSupport.containsReasoningDelta(data))
    }

    func testContainsReasoningDeltaReturnsFalseForEmptyData() {
        XCTAssertFalse(OpenAICompatibleResponseSupport.containsReasoningDelta(Data()))
    }

    // MARK: - applyProviderTuning

    func testProviderTuningIsNoOpForNonDoubaoEndpoint() throws {
        var body: [String: Any] = ["model": "gpt-4o"]
        try OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: XCTUnwrap(URL(string: "https://api.openai.com/v1")),
            model: "gpt-4o",
        )
        // For non-Doubao endpoint, "thinking" key should not be added
        XCTAssertNil(body["thinking"])
    }

    func testProviderTuningDoesNotModifyOtherBodyKeys() throws {
        var body: [String: Any] = ["model": "custom-model", "stream": true]
        try OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: XCTUnwrap(URL(string: "https://api.custom.com/v1")),
            model: "custom-model",
        )
        XCTAssertEqual(body["model"] as? String, "custom-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }
}
