@testable import Typeflux
import XCTest

final class AgentSkillRegistryTests: XCTestCase {
    // MARK: - Mock Tool for testing

    private struct StubTool: AgentTool {
        let definition: LLMAgentTool

        init(name: String) {
            definition = LLMAgentTool(
                name: name,
                description: "Stub tool: \(name)",
                inputSchema: LLMJSONSchema(
                    name: name,
                    schema: ["type": .string("object"), "properties": .object([:])],
                    strict: false,
                ),
            )
        }

        func execute(arguments _: String) async throws -> String {
            #"{"stub": "\#(definition.name)"}"#
        }
    }

    // MARK: - Register and Unregister

    func testRegisterSkill() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "test", description: "Test skill")
        let tools = [StubTool(name: "tool_a") as any AgentTool]

        await registry.register(skill: skill, tools: tools)
        let has = await registry.hasSkill(name: "test")
        XCTAssertTrue(has)
    }

    func testUnregisterSkill() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "test", description: "Test")
        await registry.register(skill: skill, tools: [])
        await registry.unregister(name: "test")

        let has = await registry.hasSkill(name: "test")
        XCTAssertFalse(has)
    }

    func testUnregisterNonexistentSkill() async {
        let registry = AgentSkillRegistry()
        await registry.unregister(name: "nonexistent")
        let has = await registry.hasSkill(name: "nonexistent")
        XCTAssertFalse(has)
    }

    // MARK: - Enabled Tools

    func testEnabledToolsReturnsToolsForEnabledSkills() async {
        let registry = AgentSkillRegistry()

        let enabledSkill = AgentSkill(name: "enabled_skill", description: "Enabled", enabled: true)
        let disabledSkill = AgentSkill(name: "disabled_skill", description: "Disabled", enabled: false)

        await registry.register(skill: enabledSkill, tools: [StubTool(name: "tool_a")])
        await registry.register(skill: disabledSkill, tools: [StubTool(name: "tool_b")])

        let tools = await registry.enabledTools()
        let toolNames = tools.map(\.definition.name)
        XCTAssertTrue(toolNames.contains("tool_a"))
        XCTAssertFalse(toolNames.contains("tool_b"))
    }

    func testEnabledToolsWithNoSkillsReturnsEmpty() async {
        let registry = AgentSkillRegistry()
        let tools = await registry.enabledTools()
        XCTAssertTrue(tools.isEmpty)
    }

    func testEnabledToolsWithMultipleToolsPerSkill() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "multi", description: "Multi tool skill", enabled: true)
        await registry.register(skill: skill, tools: [
            StubTool(name: "tool_x"),
            StubTool(name: "tool_y"),
        ])

        let tools = await registry.enabledTools()
        XCTAssertEqual(tools.count, 2)
    }

    // MARK: - Prompt Supplements

    func testEnabledPromptSupplementsReturnsOnlyEnabled() async {
        let registry = AgentSkillRegistry()

        let skill1 = AgentSkill(
            name: "s1", description: "", enabled: true,
            systemPromptSupplement: "Use tool A carefully",
        )
        let skill2 = AgentSkill(
            name: "s2", description: "", enabled: false,
            systemPromptSupplement: "Use tool B carefully",
        )

        await registry.register(skill: skill1, tools: [])
        await registry.register(skill: skill2, tools: [])

        let supplements = await registry.enabledPromptSupplements()
        XCTAssertEqual(supplements.count, 1)
        XCTAssertTrue(supplements[0].contains("tool A"))
    }

    func testEnabledPromptSupplementsExcludesEmpty() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "s", description: "", enabled: true, systemPromptSupplement: "")
        await registry.register(skill: skill, tools: [])

        let supplements = await registry.enabledPromptSupplements()
        XCTAssertTrue(supplements.isEmpty)
    }

    // MARK: - All Skills

    func testAllSkillsReturnsAll() async {
        let registry = AgentSkillRegistry()
        await registry.register(skill: AgentSkill(name: "a", description: "A"), tools: [])
        await registry.register(skill: AgentSkill(name: "b", description: "B"), tools: [])

        let all = await registry.allSkills
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - Enabled Skills

    func testEnabledSkillsFiltersCorrectly() async {
        let registry = AgentSkillRegistry()
        await registry.register(skill: AgentSkill(name: "a", description: "A", enabled: true), tools: [])
        await registry.register(skill: AgentSkill(name: "b", description: "B", enabled: false), tools: [])

        let enabled = await registry.enabledSkills
        XCTAssertEqual(enabled.count, 1)
        XCTAssertEqual(enabled[0].name, "a")
    }

    // MARK: - Set Enabled

    func testSetEnabledUpdatesSkill() async {
        let registry = AgentSkillRegistry()
        await registry.register(skill: AgentSkill(name: "s", description: "S", enabled: false), tools: [])

        await registry.setEnabled(name: "s", enabled: true)
        let skill = await registry.skill(named: "s")
        XCTAssertTrue(skill?.enabled == true)
    }

    func testSetEnabledNonexistentSkillDoesNothing() async {
        let registry = AgentSkillRegistry()
        await registry.setEnabled(name: "nonexistent", enabled: true)
        let skill = await registry.skill(named: "nonexistent")
        XCTAssertNil(skill)
    }

    // MARK: - Skill Lookup

    func testSkillNamedReturnsSkill() async {
        let registry = AgentSkillRegistry()
        await registry.register(skill: AgentSkill(name: "lookup", description: "Look"), tools: [])

        let skill = await registry.skill(named: "lookup")
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.name, "lookup")
    }

    func testSkillNamedReturnsNilForMissing() async {
        let registry = AgentSkillRegistry()
        let skill = await registry.skill(named: "missing")
        XCTAssertNil(skill)
    }

    // MARK: - Has Skill

    func testHasSkillReturnsTrueForRegistered() async {
        let registry = AgentSkillRegistry()
        await registry.register(skill: AgentSkill(name: "exists", description: ""), tools: [])
        let has = await registry.hasSkill(name: "exists")
        XCTAssertTrue(has)
    }

    func testHasSkillReturnsFalseForUnregistered() async {
        let registry = AgentSkillRegistry()
        let has = await registry.hasSkill(name: "nope")
        XCTAssertFalse(has)
    }
}

// MARK: - Extended AgentSkillRegistry tests

extension AgentSkillRegistryTests {
    func testRegisterAndRetrieveSkill() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "test_skill", description: "Test", enabled: true)
        await registry.register(skill: skill, tools: [])

        let retrieved = await registry.skill(named: "test_skill")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "test_skill")
        XCTAssertEqual(retrieved?.description, "Test")
    }

    func testHasSkillReturnsTrueForRegisteredSkill() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "my_skill", description: "Mine", enabled: true)
        await registry.register(skill: skill, tools: [])

        let hasIt = await registry.hasSkill(name: "my_skill")
        XCTAssertTrue(hasIt)
    }

    func testHasSkillReturnsFalseForUnregisteredSkill() async {
        let registry = AgentSkillRegistry()
        let result = await registry.hasSkill(name: "absent_skill")
        XCTAssertFalse(result)
    }

    func testUnregisterRemovesSkill() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "removable", description: "Remove me", enabled: true)
        await registry.register(skill: skill, tools: [])
        await registry.unregister(name: "removable")

        let hasIt = await registry.hasSkill(name: "removable")
        XCTAssertFalse(hasIt)
    }

    func testSetEnabledChangesSkillEnabledStatus() async {
        let registry = AgentSkillRegistry()
        let skill = AgentSkill(name: "toggle_skill", description: "Toggle", enabled: true)
        await registry.register(skill: skill, tools: [])

        await registry.setEnabled(name: "toggle_skill", enabled: false)

        let retrieved = await registry.skill(named: "toggle_skill")
        XCTAssertEqual(retrieved?.enabled, false)
    }

    func testSetEnabledOnNonexistentSkillDoesNotCrash() async {
        let registry = AgentSkillRegistry()
        await registry.setEnabled(name: "ghost_skill", enabled: true)
        // No crash expected
    }

    func testEnabledSkillsFiltersByEnabledStatus() async {
        let registry = AgentSkillRegistry()
        let enabled = AgentSkill(name: "enabled_skill", description: "E", enabled: true)
        let disabled = AgentSkill(name: "disabled_skill", description: "D", enabled: false)
        await registry.register(skill: enabled, tools: [])
        await registry.register(skill: disabled, tools: [])

        let enabledSkills = await registry.enabledSkills
        XCTAssertEqual(enabledSkills.count, 1)
        XCTAssertEqual(enabledSkills.first?.name, "enabled_skill")
    }

    func testAllSkillsReturnsAllRegistered() async {
        let registry = AgentSkillRegistry()
        let s1 = AgentSkill(name: "skill_a", description: "A", enabled: true)
        let s2 = AgentSkill(name: "skill_b", description: "B", enabled: false)
        await registry.register(skill: s1, tools: [])
        await registry.register(skill: s2, tools: [])

        let all = await registry.allSkills
        XCTAssertEqual(all.count, 2)
    }

    func testEnabledPromptSupplementsReturnsOnlyNonEmptyFromEnabledSkills() async {
        let registry = AgentSkillRegistry()
        let withSupplement = AgentSkill(
            name: "with_supplement",
            description: "W",
            enabled: true,
            systemPromptSupplement: "Use special rules",
        )
        let withoutSupplement = AgentSkill(
            name: "without_supplement",
            description: "WO",
            enabled: true,
            systemPromptSupplement: "",
        )
        let disabled = AgentSkill(
            name: "disabled",
            description: "D",
            enabled: false,
            systemPromptSupplement: "Should not appear",
        )
        await registry.register(skill: withSupplement, tools: [])
        await registry.register(skill: withoutSupplement, tools: [])
        await registry.register(skill: disabled, tools: [])

        let supplements = await registry.enabledPromptSupplements()
        XCTAssertEqual(supplements.count, 1)
        XCTAssertEqual(supplements.first, "Use special rules")
    }
}
