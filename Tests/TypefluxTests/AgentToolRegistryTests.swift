import XCTest
@testable import Typeflux

final class AgentToolRegistryTests: XCTestCase {

    func testRegisterAndHasTool() async throws {
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())
        let hasTool = await registry.hasTool(name: "answer_text")
        let missing = await registry.hasTool(name: "nonexistent_tool")
        XCTAssertTrue(hasTool)
        XCTAssertFalse(missing)
    }

    func testRegisterAll() async throws {
        let registry = AgentToolRegistry()
        let clipboard = MockClipboardService()
        let tools: [any AgentTool] = [
            AnswerTextTool(),
            EditTextTool(),
            GetClipboardTool(clipboardService: clipboard),
        ]
        await registry.registerAll(tools)
        let defs = await registry.definitions
        XCTAssertEqual(defs.count, 3)
        let names = defs.map(\.name).sorted()
        XCTAssertEqual(names, ["answer_text", "edit_text", "get_clipboard"])
    }

    func testUnregister() async throws {
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())
        await registry.unregister(name: "answer_text")
        let hasTool = await registry.hasTool(name: "answer_text")
        XCTAssertFalse(hasTool)
    }

    func testIsTerminationTool() async throws {
        let registry = AgentToolRegistry()
        let clipboard = MockClipboardService()
        await registry.register(AnswerTextTool())
        await registry.register(EditTextTool())
        await registry.register(GetClipboardTool(clipboardService: clipboard))

        let answerIsTermination = await registry.isTerminationTool(name: "answer_text")
        let editIsTermination = await registry.isTerminationTool(name: "edit_text")
        let clipboardIsTermination = await registry.isTerminationTool(name: "get_clipboard")
        let missingIsTermination = await registry.isTerminationTool(name: "nonexistent")

        XCTAssertTrue(answerIsTermination)
        XCTAssertTrue(editIsTermination)
        XCTAssertFalse(clipboardIsTermination)
        XCTAssertFalse(missingIsTermination)
    }

    func testExecuteKnownTool() async throws {
        let registry = AgentToolRegistry()
        let clipboard = MockClipboardService()
        clipboard.storedText = "test content"
        await registry.register(GetClipboardTool(clipboardService: clipboard))

        let result = try await registry.execute(name: "get_clipboard", arguments: "{}", toolCallId: "tc1")
        XCTAssertEqual(result.toolCallId, "tc1")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("test content"))
    }

    func testExecuteUnknownToolThrows() async throws {
        let registry = AgentToolRegistry()
        do {
            _ = try await registry.execute(name: "nonexistent", arguments: "{}", toolCallId: "tc1")
            XCTFail("Expected toolNotFound error")
        } catch AgentError.toolNotFound(let name) {
            XCTAssertEqual(name, "nonexistent")
        }
    }

    func testExecuteToolWithErrorReturnsErrorResult() async throws {
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())

        // invalid args should cause an error result (not a throw)
        let result = try await registry.execute(name: "answer_text", arguments: "invalid json", toolCallId: "tc1")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.toolCallId, "tc1")
    }

    func testUnregisterRemovesTerminationStatus() async throws {
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())
        await registry.unregister(name: "answer_text")
        let isTermination = await registry.isTerminationTool(name: "answer_text")
        XCTAssertFalse(isTermination)
    }

    func testDefinitionsCountMatchesRegistered() async throws {
        let registry = AgentToolRegistry()
        let defsEmpty = await registry.definitions
        XCTAssertTrue(defsEmpty.isEmpty)

        await registry.register(AnswerTextTool())
        let defsOne = await registry.definitions
        XCTAssertEqual(defsOne.count, 1)

        await registry.register(EditTextTool())
        let defsTwo = await registry.definitions
        XCTAssertEqual(defsTwo.count, 2)
    }
}
