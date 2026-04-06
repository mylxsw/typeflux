@testable import Typeflux
import XCTest

final class AgentPromptCatalogTests: XCTestCase {
    // MARK: - routerSystemPrompt

    func testRouterSystemPromptIncludesToolDescriptions() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("answer_text"))
        XCTAssertTrue(prompt.contains("edit_text"))
        XCTAssertTrue(prompt.contains("run_agent"))
    }

    func testRouterSystemPromptIncludesDecisionRules() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("Default to answer_text"))
        XCTAssertTrue(prompt.contains("Use run_agent only when the task truly cannot be done in a single response"))
    }

    func testRouterSystemPromptIncludesLanguageConsistencyRule() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("Language consistency rule"))
    }

    func testRouterSystemPromptWithPersona() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: "Be formal and concise")
        XCTAssertTrue(prompt.contains("<persona_definition>"))
        XCTAssertTrue(prompt.contains("Be formal and concise"))
    }

    func testRouterSystemPromptWithNilPersona() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: nil)
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    func testRouterSystemPromptWithEmptyPersona() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: "  ")
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    func testRouterSystemPromptWithWhitespaceOnlyPersona() {
        let prompt = AgentPromptCatalog.routerSystemPrompt(personaPrompt: "\n\t\n")
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    // MARK: - routerUserPrompt

    func testRouterUserPromptWithInstructionOnly() {
        let prompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: nil,
            instruction: "What is the weather?"
        )
        XCTAssertTrue(prompt.contains("<spoken_request>\nWhat is the weather?\n</spoken_request>"))
        XCTAssertFalse(prompt.contains("<selected_text>"))
    }

    func testRouterUserPromptWithSelectedText() {
        let prompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: "Hello, world!",
            instruction: "Translate this"
        )
        XCTAssertTrue(prompt.contains("<selected_text>\nHello, world!\n</selected_text>"))
        XCTAssertTrue(prompt.contains("<spoken_request>\nTranslate this\n</spoken_request>"))
    }

    func testRouterUserPromptWithEmptySelectedText() {
        let prompt = AgentPromptCatalog.routerUserPrompt(
            selectedText: "  ",
            instruction: "Do something"
        )
        XCTAssertFalse(prompt.contains("<selected_text>"))
    }

    // MARK: - agentSystemPrompt

    func testAgentSystemPromptIncludesToolDescriptions() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("answer_text"))
        XCTAssertTrue(prompt.contains("edit_text"))
    }

    func testAgentSystemPromptIncludesDecisionRules() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("Default to answer_text"))
        XCTAssertTrue(prompt.contains("prefer answer_text over edit_text"))
    }

    func testAgentSystemPromptIncludesLanguageConsistencyRule() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("Language consistency rule"))
    }

    func testAgentSystemPromptWithPersona() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: "Be formal and concise")
        XCTAssertTrue(prompt.contains("<persona_definition>"))
        XCTAssertTrue(prompt.contains("Be formal and concise"))
    }

    func testAgentSystemPromptWithNilPersona() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: nil)
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    func testAgentSystemPromptWithEmptyPersona() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: "  ")
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    func testAgentSystemPromptWithWhitespaceOnlyPersona() {
        let prompt = AgentPromptCatalog.agentSystemPrompt(personaPrompt: "\n\t\n")
        XCTAssertFalse(prompt.contains("<persona_definition>"))
    }

    // MARK: - agentUserPrompt

    func testAgentUserPromptWithInstructionOnly() {
        let prompt = AgentPromptCatalog.agentUserPrompt(
            selectedText: nil,
            spokenInstruction: "What is the weather?",
            detailedInstruction: "Provide the current weather."
        )
        XCTAssertTrue(prompt.contains("<original_request>\nWhat is the weather?\n</original_request>"))
        XCTAssertTrue(prompt.contains("<task_instruction>\nProvide the current weather.\n</task_instruction>"))
        XCTAssertFalse(prompt.contains("<selected_text>"))
    }

    func testAgentUserPromptWithSelectedText() {
        let prompt = AgentPromptCatalog.agentUserPrompt(
            selectedText: "Hello, world!",
            spokenInstruction: "Translate this",
            detailedInstruction: "Translate to French"
        )
        XCTAssertTrue(prompt.contains("<selected_text>\nHello, world!\n</selected_text>"))
        XCTAssertTrue(prompt.contains("<original_request>\nTranslate this\n</original_request>"))
        XCTAssertTrue(prompt.contains("<task_instruction>\nTranslate to French\n</task_instruction>"))
    }

    func testAgentUserPromptWithEmptySelectedText() {
        let prompt = AgentPromptCatalog.agentUserPrompt(
            selectedText: "  ",
            spokenInstruction: "Do something",
            detailedInstruction: "Detailed do something"
        )
        XCTAssertFalse(prompt.contains("<selected_text>"))
    }
}
