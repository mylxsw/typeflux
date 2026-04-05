import XCTest
@testable import Typeflux

// MARK: - Mock LLM Service

private final class MockLLMService: LLMService, @unchecked Sendable {
    var completeResult: String = "Generated Title"
    var shouldThrow = false
    var capturedSystemPrompt: String?
    var capturedUserPrompt: String?

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        capturedSystemPrompt = systemPrompt
        capturedUserPrompt = userPrompt
        if shouldThrow {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "LLM Error"])
        }
        return completeResult
    }

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        return "{}"
    }
}

final class AgentJobTitleGeneratorTests: XCTestCase {

    private func makeJob(
        prompt: String = "Translate this email to Japanese",
        selectedText: String? = "Hello, how are you?",
        resultText: String? = "こんにちは、お元気ですか？",
        steps: [AgentJobStep] = []
    ) -> AgentJob {
        AgentJob(
            status: .completed,
            title: nil,
            userPrompt: prompt,
            selectedText: selectedText,
            resultText: resultText,
            steps: steps
        )
    }

    // MARK: - Basic Generation

    func testGeneratesTitleSuccessfully() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = "Translated email to Japanese"

        let job = makeJob()
        let title = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertEqual(title, "Translated email to Japanese")
    }

    // MARK: - Prompt Construction

    func testPromptIncludesUserRequest() async {
        let mockLLM = MockLLMService()
        let job = makeJob(prompt: "Summarize this text")
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertTrue(mockLLM.capturedUserPrompt?.contains("Summarize this text") ?? false)
    }

    func testPromptIncludesSelectedText() async {
        let mockLLM = MockLLMService()
        let job = makeJob(selectedText: "Some context text")
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertTrue(mockLLM.capturedUserPrompt?.contains("Context text:") ?? false)
        XCTAssertTrue(mockLLM.capturedUserPrompt?.contains("Some context text") ?? false)
    }

    func testPromptExcludesEmptySelectedText() async {
        let mockLLM = MockLLMService()
        let job = makeJob(selectedText: "")
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertFalse(mockLLM.capturedUserPrompt?.contains("Context text:") ?? true)
    }

    func testPromptExcludesNilSelectedText() async {
        let mockLLM = MockLLMService()
        let job = makeJob(selectedText: nil)
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertFalse(mockLLM.capturedUserPrompt?.contains("Context text:") ?? true)
    }

    func testPromptIncludesResultText() async {
        let mockLLM = MockLLMService()
        let job = makeJob(resultText: "The answer is 42")
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertTrue(mockLLM.capturedUserPrompt?.contains("Result:") ?? false)
    }

    func testPromptExcludesEmptyResultText() async {
        let mockLLM = MockLLMService()
        let job = makeJob(resultText: "")
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertFalse(mockLLM.capturedUserPrompt?.contains("Result:") ?? true)
    }

    func testPromptIncludesToolNames() async {
        let mockLLM = MockLLMService()
        let tc1 = AgentJobToolCall(id: "1", name: "search", argumentsJSON: "{}", resultContent: "", isError: false)
        let tc2 = AgentJobToolCall(id: "2", name: "clipboard", argumentsJSON: "{}", resultContent: "", isError: false)
        let step = AgentJobStep(stepIndex: 0, toolCalls: [tc1, tc2], assistantText: nil, durationMs: 100)
        let job = makeJob(steps: [step])
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertTrue(mockLLM.capturedUserPrompt?.contains("Tools used:") ?? false)
    }

    func testPromptTruncatesLongSelectedText() async {
        let mockLLM = MockLLMService()
        let longText = String(repeating: "a", count: 500)
        let job = makeJob(selectedText: longText)
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        // The selected text in prompt should be truncated to 200 chars
        let prompt = mockLLM.capturedUserPrompt ?? ""
        let contextRange = prompt.range(of: "Context text: ")!
        let afterContext = prompt[contextRange.upperBound...]
        let contextLine = afterContext.prefix(while: { $0 != "\n" })
        XCTAssertLessThanOrEqual(contextLine.count, 200)
    }

    // MARK: - Response Cleaning

    func testCleansWhitespace() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = "  Clean Title  \n"
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertEqual(title, "Clean Title")
    }

    func testCleansQuotes() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = "\"Quoted Title\""
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertEqual(title, "Quoted Title")
    }

    func testCleansPeriod() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = "Title with period."
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertEqual(title, "Title with period")
    }

    func testCleansSingleQuotes() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = "'Single Quoted'"
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertEqual(title, "Single Quoted")
    }

    // MARK: - Edge Cases

    func testReturnsNilOnError() async {
        let mockLLM = MockLLMService()
        mockLLM.shouldThrow = true
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertNil(title)
    }

    func testReturnsNilOnEmptyResponse() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = ""
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertNil(title)
    }

    func testReturnsNilOnWhitespaceOnlyResponse() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = "   \n\t  "
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertNil(title)
    }

    func testReturnsNilOnTooLongResponse() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = String(repeating: "x", count: 101)
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertNil(title)
    }

    func testAcceptsTitleAtMaxLength() async {
        let mockLLM = MockLLMService()
        mockLLM.completeResult = String(repeating: "x", count: 100)
        let title = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)
        XCTAssertNotNil(title)
        XCTAssertEqual(title?.count, 100)
    }

    // MARK: - System Prompt

    func testSystemPromptContainsRules() async {
        let mockLLM = MockLLMService()
        _ = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)

        let systemPrompt = mockLLM.capturedSystemPrompt ?? ""
        XCTAssertTrue(systemPrompt.contains("50 characters"))
        XCTAssertTrue(systemPrompt.contains("ONLY the title"))
    }

    func testPromptEndsWithGenerateInstruction() async {
        let mockLLM = MockLLMService()
        _ = await AgentJobTitleGenerator.generateTitle(for: makeJob(), using: mockLLM)

        XCTAssertTrue(mockLLM.capturedUserPrompt?.contains("Generate a short title") ?? false)
    }

    // MARK: - No Steps / No Tools

    func testNoStepsMeansNoToolsUsedLine() async {
        let mockLLM = MockLLMService()
        let job = makeJob(steps: [])
        _ = await AgentJobTitleGenerator.generateTitle(for: job, using: mockLLM)

        XCTAssertFalse(mockLLM.capturedUserPrompt?.contains("Tools used:") ?? true)
    }
}
