@testable import Typeflux
import XCTest

final class AgentSkillTests: XCTestCase {
    // MARK: - AgentSkill Init

    func testAgentSkillDefaultInit() {
        let skill = AgentSkill(
            name: "test_skill",
            description: "A test skill",
        )
        XCTAssertFalse(skill.id.uuidString.isEmpty)
        XCTAssertEqual(skill.name, "test_skill")
        XCTAssertEqual(skill.description, "A test skill")
        XCTAssertTrue(skill.enabled)
        XCTAssertEqual(skill.systemPromptSupplement, "")
        XCTAssertTrue(skill.toolNames.isEmpty)
    }

    func testAgentSkillCustomInit() {
        let id = UUID()
        let skill = AgentSkill(
            id: id,
            name: "custom_skill",
            description: "Custom",
            enabled: false,
            systemPromptSupplement: "Use carefully",
            toolNames: ["tool_a", "tool_b"],
        )
        XCTAssertEqual(skill.id, id)
        XCTAssertEqual(skill.name, "custom_skill")
        XCTAssertFalse(skill.enabled)
        XCTAssertEqual(skill.systemPromptSupplement, "Use carefully")
        XCTAssertEqual(skill.toolNames, ["tool_a", "tool_b"])
    }

    func testAgentSkillCodableRoundTrip() throws {
        let skill = AgentSkill(
            name: "codable_skill",
            description: "Test codability",
            enabled: true,
            systemPromptSupplement: "Be nice",
            toolNames: ["tool_x"],
        )
        let data = try JSONEncoder().encode(skill)
        let decoded = try JSONDecoder().decode(AgentSkill.self, from: data)
        XCTAssertEqual(decoded.id, skill.id)
        XCTAssertEqual(decoded.name, skill.name)
        XCTAssertEqual(decoded.description, skill.description)
        XCTAssertEqual(decoded.enabled, skill.enabled)
        XCTAssertEqual(decoded.systemPromptSupplement, skill.systemPromptSupplement)
        XCTAssertEqual(decoded.toolNames, skill.toolNames)
    }

    func testAgentSkillCodableArray() throws {
        let skills = [
            AgentSkill(name: "a", description: "A"),
            AgentSkill(name: "b", description: "B", enabled: false),
        ]
        let data = try JSONEncoder().encode(skills)
        let decoded = try JSONDecoder().decode([AgentSkill].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "a")
        XCTAssertEqual(decoded[1].name, "b")
        XCTAssertFalse(decoded[1].enabled)
    }

    // MARK: - BuiltinSkillName

    func testBuiltinSkillNameRawValues() {
        XCTAssertEqual(BuiltinSkillName.commandExecution.rawValue, "command_execution")
        XCTAssertEqual(BuiltinSkillName.webAccess.rawValue, "web_access")
    }

    func testBuiltinSkillNameAllCases() {
        XCTAssertEqual(BuiltinSkillName.allCases.count, 2)
    }

    // MARK: - BuiltinSkillCatalog

    func testBuiltinCommandExecutionSkill() {
        let skill = BuiltinSkillCatalog.commandExecution()
        XCTAssertEqual(skill.name, "command_execution")
        XCTAssertFalse(skill.description.isEmpty)
        XCTAssertFalse(skill.enabled)
        XCTAssertFalse(skill.systemPromptSupplement.isEmpty)
        XCTAssertTrue(skill.toolNames.contains("shell_command"))
    }

    func testBuiltinWebAccessSkill() {
        let skill = BuiltinSkillCatalog.webAccess()
        XCTAssertEqual(skill.name, "web_access")
        XCTAssertFalse(skill.description.isEmpty)
        XCTAssertFalse(skill.enabled)
        XCTAssertFalse(skill.systemPromptSupplement.isEmpty)
        XCTAssertTrue(skill.toolNames.contains("web_fetch"))
    }

    func testBuiltinSkillCatalogAll() {
        let all = BuiltinSkillCatalog.all
        XCTAssertEqual(all.count, 2)
        let names = all.map(\.name)
        XCTAssertTrue(names.contains("command_execution"))
        XCTAssertTrue(names.contains("web_access"))
    }

    func testBuiltinSkillsDefaultDisabled() {
        for skill in BuiltinSkillCatalog.all {
            XCTAssertFalse(skill.enabled, "\(skill.name) should be disabled by default")
        }
    }

    // MARK: - BuiltinToolName

    func testBuiltinToolNameRawValues() {
        XCTAssertEqual(BuiltinToolName.shellCommand.rawValue, "shell_command")
        XCTAssertEqual(BuiltinToolName.webFetch.rawValue, "web_fetch")
    }

    func testBuiltinToolNameAllCases() {
        XCTAssertEqual(BuiltinToolName.allCases.count, 2)
    }
}
