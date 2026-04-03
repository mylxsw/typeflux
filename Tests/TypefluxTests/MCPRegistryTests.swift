import XCTest
@testable import Typeflux

final class MCPRegistryTests: XCTestCase {

    func testRegistryInitializesEmpty() async {
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "test.mcp.registry.\(UUID())")!))
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }

    func testAllMCPToolsEmptyByDefault() async {
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "test.mcp.registry.\(UUID())")!))
        let tools = await registry.allMCPTools()
        XCTAssertTrue(tools.isEmpty)
    }

    func testServerIdForUnknownToolReturnsNil() async {
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "test.mcp.registry.\(UUID())")!))
        let id = await registry.serverId(forToolName: "nonexistent_tool")
        XCTAssertNil(id)
    }

    func testRemoveNonexistentServerDoesNotCrash() async {
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "test.mcp.registry.\(UUID())")!))
        await registry.removeServer(id: UUID())
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }
}
