@testable import Typeflux
import XCTest

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

    // MARK: - mcpServers

    func testAgentStepLimitDefaultsPersistsAndClamps() {
        XCTAssertEqual(store.askAgentMaxSteps, 200)
        store.askAgentMaxSteps = 200
        XCTAssertEqual(SettingsStore(defaults: defaults).askAgentMaxSteps, 200)
        store.askAgentMaxSteps = 1001
        XCTAssertEqual(store.askAgentMaxSteps, 1000)
        XCTAssertTrue(SettingsStore.askAgentMaxStepOptions.contains(1000))
        store.askAgentMaxSteps = 700
        XCTAssertEqual(SettingsStore(defaults: defaults).askAgentMaxSteps, 700)
        store.askAgentMaxSteps = 100
        XCTAssertEqual(store.askAgentMaxSteps, 100)
        defaults.set(-1, forKey: "ask.agentMaxSteps")
        XCTAssertEqual(store.askAgentMaxSteps, 200)
    }

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
            transport: .http(MCPHTTPTransportConfig(
                url: "https://example.com/mcp",
                headers: ["Authorization": "Bearer tok"]
            )),
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
            )
        ]

        store.mcpServers = servers

        let loaded = store.mcpServers
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "server-a")
        XCTAssertEqual(loaded[1].name, "server-b")
    }
}
