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

// MARK: - Extended MCPRegistry tests

final class MCPRegistryExtendedTests: XCTestCase {

    private func makeRegistry() -> MCPRegistry {
        MCPRegistry(settingsStore: MCPSettingsStore(
            defaults: UserDefaults(suiteName: "test.mcp.ext.\(UUID().uuidString)")!
        ))
    }

    func testRemoveNonExistentServerMultipleTimesIsSafe() async {
        let registry = makeRegistry()
        let nonExistentID = UUID()
        await registry.removeServer(id: nonExistentID)
        await registry.removeServer(id: nonExistentID)
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }

    func testServerIdForToolWithNoServersReturnsNil() async {
        let registry = makeRegistry()
        let result = await registry.serverId(forToolName: "some_tool")
        XCTAssertNil(result)
    }

    func testAllMCPToolsReturnsEmptyArrayInitially() async {
        let registry = makeRegistry()
        let tools = await registry.allMCPTools()
        XCTAssertEqual(tools.count, 0)
    }

    func testConnectedServerCountIsZeroInitially() async {
        let registry = makeRegistry()
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }

    func testConnectAutoConnectServersWithEmptySettingsDoesNotCrash() async {
        let registry = makeRegistry()
        await registry.connectAutoConnectServers()
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }
}
