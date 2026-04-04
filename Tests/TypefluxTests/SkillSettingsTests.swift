import XCTest
@testable import Typeflux

final class SkillSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SkillSettingsStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SkillSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SkillSettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Default Skills

    func testDefaultSkillsIncludeBuiltins() {
        let skills = store.skills
        let names = skills.map(\.name)
        XCTAssertTrue(names.contains("command_execution"))
        XCTAssertTrue(names.contains("web_access"))
    }

    func testDefaultSkillsAreDisabled() {
        let skills = store.skills
        for skill in skills {
            XCTAssertFalse(skill.enabled, "\(skill.name) should be disabled by default")
        }
    }

    // MARK: - Set and Get

    func testSetAndGetSkills() {
        let custom = [
            AgentSkill(name: "custom_skill", description: "My custom skill", enabled: true),
        ]
        store.skills = custom

        let loaded = store.skills
        // Should have custom + builtin skills
        XCTAssertTrue(loaded.count >= 3, "Should include custom + 2 builtins")
        let names = loaded.map(\.name)
        XCTAssertTrue(names.contains("custom_skill"))
        XCTAssertTrue(names.contains("command_execution"))
        XCTAssertTrue(names.contains("web_access"))
    }

    func testUpdateSkillEnabled() {
        // Start with defaults
        _ = store.skills

        store.updateSkillEnabled(name: "command_execution", enabled: true)
        let skills = store.skills
        let cmdSkill = skills.first(where: { $0.name == "command_execution" })
        XCTAssertTrue(cmdSkill?.enabled == true)
    }

    func testUpdateNonexistentSkillDoesNothing() {
        let before = store.skills
        store.updateSkillEnabled(name: "nonexistent", enabled: true)
        let after = store.skills
        XCTAssertEqual(before.count, after.count)
    }

    // MARK: - Add and Remove

    func testAddSkill() {
        let newSkill = AgentSkill(name: "new", description: "New skill")
        store.addSkill(newSkill)

        let skills = store.skills
        let names = skills.map(\.name)
        XCTAssertTrue(names.contains("new"))
    }

    func testRemoveSkill() {
        let skills = store.skills
        guard let first = skills.first else {
            XCTFail("Expected at least one skill")
            return
        }

        store.removeSkill(id: first.id)
        let updated = store.skills
        // Builtin skills may come back from merge
        let directLoad = defaults.data(forKey: "agent.skills").flatMap { try? JSONDecoder().decode([AgentSkill].self, from: $0) } ?? []
        XCTAssertFalse(directLoad.contains(where: { $0.id == first.id }))
    }

    // MARK: - Reset to Defaults

    func testResetToDefaults() {
        store.updateSkillEnabled(name: "command_execution", enabled: true)
        store.resetToDefaults()

        let skills = store.skills
        let cmdSkill = skills.first(where: { $0.name == "command_execution" })
        XCTAssertFalse(cmdSkill?.enabled ?? true, "Should be reset to default disabled state")
    }

    // MARK: - Merge with Builtins

    func testMergePreservesExistingSkills() {
        let custom = [AgentSkill(name: "my_skill", description: "Custom")]
        store.skills = custom

        let loaded = store.skills
        XCTAssertTrue(loaded.contains(where: { $0.name == "my_skill" }))
    }

    func testMergeAddsNewBuiltins() {
        // Simulate old data that only has one builtin
        let partial = [BuiltinSkillCatalog.commandExecution()]
        if let data = try? JSONEncoder().encode(partial) {
            defaults.set(data, forKey: "agent.skills")
        }

        let loaded = store.skills
        let names = loaded.map(\.name)
        XCTAssertTrue(names.contains("command_execution"))
        XCTAssertTrue(names.contains("web_access"))
    }

    // MARK: - Persistence Round Trip

    func testSkillPersistenceRoundTrip() {
        let skill = AgentSkill(
            name: "round_trip",
            description: "Testing persistence",
            enabled: true,
            systemPromptSupplement: "Be careful",
            toolNames: ["tool_1", "tool_2"]
        )
        store.skills = [skill]

        let loaded = store.skills
        let found = loaded.first(where: { $0.name == "round_trip" })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.description, "Testing persistence")
        XCTAssertTrue(found?.enabled == true)
        XCTAssertEqual(found?.systemPromptSupplement, "Be careful")
        XCTAssertEqual(found?.toolNames, ["tool_1", "tool_2"])
    }
}
