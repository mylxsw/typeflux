import XCTest
@testable import Typeflux

final class OpenAICompatibleResponseSupportTests: XCTestCase {
    func testExtractsPlainStringDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": "hello"]]
            ]
        ])

        XCTAssertEqual(OpenAICompatibleResponseSupport.extractTextDelta(from: data), "hello")
    }

    func testExtractsStructuredTextDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["content": [["type": "text", "text": "hello"], ["type": "text", "text": " world"]]]]
            ]
        ])

        XCTAssertEqual(OpenAICompatibleResponseSupport.extractTextDelta(from: data), "hello world")
    }

    func testExtractsStructuredMarkdownBlocksWithoutFlatteningParagraphs() throws {
        let data = try jsonData([
            "choices": [
                ["message": ["content": [
                    ["type": "text", "text": "## Summary"],
                    ["type": "text", "text": "- first item\n- second item"]
                ]]]
            ]
        ])

        XCTAssertEqual(
            OpenAICompatibleResponseSupport.extractTextDelta(from: data),
            "## Summary\n\n- first item\n- second item"
        )
    }

    func testDetectsReasoningOnlyDelta() throws {
        let data = try jsonData([
            "choices": [
                ["delta": ["reasoning_content": "step by step"]]
            ]
        ])

        XCTAssertNil(OpenAICompatibleResponseSupport.extractTextDelta(from: data))
        XCTAssertTrue(OpenAICompatibleResponseSupport.containsReasoningDelta(data))
    }

    func testProviderTuningDisablesThinkingForDoubaoEndpoints() throws {
        var body: [String: Any] = [:]
        OpenAICompatibleResponseSupport.applyProviderTuning(
            body: &body,
            baseURL: try XCTUnwrap(URL(string: "https://ark.cn-beijing.volces.com/api/v3")),
            model: "doubao-seed-1-6"
        )

        let thinking = try XCTUnwrap(body["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
