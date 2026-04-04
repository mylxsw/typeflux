import XCTest
@testable import Typeflux

final class AgentPromptCatalogTests: XCTestCase {

    // MARK: - askAgentSystemPrompt

    func testSystemPromptIncludesToolDescriptions() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("answer_text"))
        XCTAssertTrue(prompt.contains("edit_text"))
        XCTAssertTrue(prompt.contains("get_clipboard"))
    }

    func testSystemPromptIncludesDecisionRules() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("Default to answer_text"))
        XCTAssertTrue(prompt.contains("prefer answer_text"))
    }

    func testSystemPromptIncludesLanguageConsistencyRule() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: nil)
        XCTAssertTrue(prompt.contains("Language consistency rule"))
    }

    func testSystemPromptWithPersona() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: "Be formal and concise")
        XCTAssertTrue(prompt.contains("Persona/style guidance"))
        XCTAssertTrue(prompt.contains("Be formal and concise"))
    }

    func testSystemPromptWithNilPersona() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: nil)
        XCTAssertFalse(prompt.contains("Persona/style guidance"))
    }

    func testSystemPromptWithEmptyPersona() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: "  ")
        XCTAssertFalse(prompt.contains("Persona/style guidance"))
    }

    func testSystemPromptWithWhitespaceOnlyPersona() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(personaPrompt: "\n\t\n")
        XCTAssertFalse(prompt.contains("Persona/style guidance"))
    }

    // MARK: - Skill supplements

    func testSystemPromptIncludesSkillSupplements() {
        let supplements = ["Use shell_command to run commands.", "Use web_fetch to look up URLs."]
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(
            personaPrompt: nil,
            skillSupplements: supplements
        )
        XCTAssertTrue(prompt.contains("Use shell_command to run commands."))
        XCTAssertTrue(prompt.contains("Use web_fetch to look up URLs."))
    }

    func testSystemPromptWithEmptySkillSupplements() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(
            personaPrompt: nil,
            skillSupplements: []
        )
        // Should still work normally
        XCTAssertTrue(prompt.contains("answer_text"))
    }

    func testSystemPromptSkipsEmptySupplementStrings() {
        let supplements = ["", "  ", "Valid supplement"]
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(
            personaPrompt: nil,
            skillSupplements: supplements
        )
        XCTAssertTrue(prompt.contains("Valid supplement"))
    }

    func testSystemPromptWithPersonaAndSkillSupplements() {
        let prompt = AgentPromptCatalog.askAgentSystemPrompt(
            personaPrompt: "Be concise",
            skillSupplements: ["Skill guidance here"]
        )
        XCTAssertTrue(prompt.contains("Persona/style guidance"))
        XCTAssertTrue(prompt.contains("Be concise"))
        XCTAssertTrue(prompt.contains("Skill guidance here"))
    }

    // MARK: - askAgentUserPrompt

    func testUserPromptWithInstructionOnly() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: nil,
            instruction: "What is the weather?"
        )
        XCTAssertTrue(prompt.contains("User request: What is the weather?"))
        XCTAssertFalse(prompt.contains("Selected text:"))
    }

    func testUserPromptWithSelectedText() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: "Hello, world!",
            instruction: "Translate this"
        )
        XCTAssertTrue(prompt.contains("Selected text:\n---\nHello, world!\n---"))
        XCTAssertTrue(prompt.contains("User request: Translate this"))
    }

    func testUserPromptWithEmptySelectedText() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: "  ",
            instruction: "Do something"
        )
        XCTAssertFalse(prompt.contains("Selected text:"))
    }

    func testUserPromptPartsJoinedWithDoubleNewline() {
        let prompt = AgentPromptCatalog.askAgentUserPrompt(
            selectedText: "some text",
            instruction: "explain"
        )
        XCTAssertTrue(prompt.contains("---\n\nUser request:"))
    }
}
