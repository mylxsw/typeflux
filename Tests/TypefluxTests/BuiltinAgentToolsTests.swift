import XCTest
@testable import Typeflux

// MARK: - Mocks

final class MockClipboardService: ClipboardService, @unchecked Sendable {
    var storedText: String?

    func write(text: String) {
        storedText = text
    }

    func getString() -> String? {
        storedText
    }
}

// MARK: - Tests

final class BuiltinAgentToolsTests: XCTestCase {

    // MARK: AnswerTextTool

    func testAnswerTextToolDefinition() {
        let tool = AnswerTextTool()
        XCTAssertEqual(tool.definition.name, "answer_text")
        XCTAssertFalse(tool.definition.description.isEmpty)
    }

    func testAnswerTextToolIsTerminationTool() {
        let tool = AnswerTextTool()
        XCTAssertTrue(tool is any TerminationTool)
    }

    func testAnswerTextToolExecuteValidArgs() async throws {
        let tool = AnswerTextTool()
        let args = #"{"answer": "42"}"#
        let result = try await tool.execute(arguments: args)
        XCTAssertEqual(result, args)
    }

    func testAnswerTextToolExecuteInvalidArgs() async {
        let tool = AnswerTextTool()
        do {
            _ = try await tool.execute(arguments: "not json")
            XCTFail("Expected error for invalid args")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testAnswerTextToolExecuteWithFormat() async throws {
        let tool = AnswerTextTool()
        let args = #"{"answer": "Hello", "format": "markdown"}"#
        let result = try await tool.execute(arguments: args)
        XCTAssertEqual(result, args)
    }

    // MARK: EditTextTool

    func testEditTextToolDefinition() {
        let tool = EditTextTool()
        XCTAssertEqual(tool.definition.name, "edit_text")
        XCTAssertFalse(tool.definition.description.isEmpty)
    }

    func testEditTextToolIsTerminationTool() {
        let tool = EditTextTool()
        XCTAssertTrue(tool is any TerminationTool)
    }

    func testEditTextToolExecuteReturnsArguments() async throws {
        let tool = EditTextTool()
        let args = #"{"replacement": "New text here"}"#
        let result = try await tool.execute(arguments: args)
        XCTAssertEqual(result, args)
    }

    // MARK: GetClipboardTool

    func testGetClipboardToolDefinition() {
        let clipboard = MockClipboardService()
        let tool = GetClipboardTool(clipboardService: clipboard)
        XCTAssertEqual(tool.definition.name, "get_clipboard")
        XCTAssertFalse(tool.definition.description.isEmpty)
    }

    func testGetClipboardToolNotTerminationTool() {
        let clipboard = MockClipboardService()
        let tool = GetClipboardTool(clipboardService: clipboard)
        XCTAssertFalse(tool is any TerminationTool)
    }

    func testGetClipboardToolWithContent() async throws {
        let clipboard = MockClipboardService()
        clipboard.storedText = "Hello clipboard"
        let tool = GetClipboardTool(clipboardService: clipboard)
        let result = try await tool.execute(arguments: "{}")
        XCTAssertTrue(result.contains("Hello clipboard"))
        XCTAssertTrue(result.contains("\"content\""))
    }

    func testGetClipboardToolEmpty() async throws {
        let clipboard = MockClipboardService()
        clipboard.storedText = nil
        let tool = GetClipboardTool(clipboardService: clipboard)
        let result = try await tool.execute(arguments: "{}")
        XCTAssertTrue(result.contains("\"error\""))
    }

    func testGetClipboardToolEscapesSpecialCharacters() async throws {
        let clipboard = MockClipboardService()
        clipboard.storedText = "line1\nline2\t\"quoted\""
        let tool = GetClipboardTool(clipboardService: clipboard)
        let result = try await tool.execute(arguments: "{}")
        // Should be valid JSON
        let data = result.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
