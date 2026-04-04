import XCTest
@testable import Typeflux

final class SettingsStoreAgentTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreAgentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - agentFrameworkEnabled

    func testAgentFrameworkEnabledDefaultsToFalse() {
        XCTAssertFalse(store.agentFrameworkEnabled)
    }

    func testAgentFrameworkEnabledSetAndGet() {
        store.agentFrameworkEnabled = true
        XCTAssertTrue(store.agentFrameworkEnabled)

        store.agentFrameworkEnabled = false
        XCTAssertFalse(store.agentFrameworkEnabled)
    }

    // MARK: - agentEnabled

    func testAgentEnabledDefaultsToTrue() {
        XCTAssertTrue(store.agentEnabled)
    }

    func testAgentEnabledSetAndGet() {
        store.agentEnabled = false
        XCTAssertFalse(store.agentEnabled)

        store.agentEnabled = true
        XCTAssertTrue(store.agentEnabled)
    }

    // MARK: - agentStepLoggingEnabled

    func testAgentStepLoggingEnabledDefaultsToFalse() {
        XCTAssertFalse(store.agentStepLoggingEnabled)
    }

    func testAgentStepLoggingEnabledSetAndGet() {
        store.agentStepLoggingEnabled = true
        XCTAssertTrue(store.agentStepLoggingEnabled)

        store.agentStepLoggingEnabled = false
        XCTAssertFalse(store.agentStepLoggingEnabled)
    }

    // MARK: - mcpServers

    func testMCPServersDefaultsToEmptyArray() {
        XCTAssertEqual(store.mcpServers.count, 0)
    }

    func testMCPServersSetAndGet() {
        let server = MCPServerConfig(
            name: "test-server",
            transport: .stdio(MCPStdioTransportConfig(command: "/usr/bin/echo", args: ["hello"])),
            enabled: true,
            autoConnect: false
        )

        store.mcpServers = [server]

        let loaded = store.mcpServers
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "test-server")
        XCTAssertEqual(loaded.first?.enabled, true)
        XCTAssertEqual(loaded.first?.autoConnect, false)
    }

    func testMCPServersRoundTripsHTTPTransport() {
        let server = MCPServerConfig(
            name: "http-server",
            transport: .http(MCPHTTPTransportConfig(url: "https://example.com/mcp", headers: ["Authorization": "Bearer tok"])),
            enabled: false,
            autoConnect: true
        )

        store.mcpServers = [server]

        let loaded = store.mcpServers
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "http-server")
        XCTAssertEqual(loaded.first?.enabled, false)
        XCTAssertEqual(loaded.first?.autoConnect, true)
    }

    func testMCPServersPreservesMultipleServers() {
        let servers = [
            MCPServerConfig(
                name: "server-a",
                transport: .stdio(MCPStdioTransportConfig(command: "a"))
            ),
            MCPServerConfig(
                name: "server-b",
                transport: .stdio(MCPStdioTransportConfig(command: "b"))
            ),
        ]

        store.mcpServers = servers

        let loaded = store.mcpServers
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "server-a")
        XCTAssertEqual(loaded[1].name, "server-b")
    }
}
