import XCTest
@testable import Typeflux

final class MCPSettingsTests: XCTestCase {

    private func makeStore() -> MCPSettingsStore {
        let suiteName = "test.mcp.settings.\(UUID())"
        return MCPSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testServersEmptyByDefault() {
        let store = makeStore()
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testAddServer() {
        let store = makeStore()
        let config = MCPServerConfig(
            name: "TestServer",
            transport: .stdio(MCPStdioTransportConfig(command: "/usr/bin/echo")),
            enabled: true,
            autoConnect: false
        )
        store.addServer(config)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers[0].name, "TestServer")
    }

    func testRemoveServer() {
        let store = makeStore()
        let config = MCPServerConfig(
            name: "ToRemove",
            transport: .http(MCPHTTPTransportConfig(url: "http://localhost:8080")),
            enabled: true,
            autoConnect: false
        )
        store.addServer(config)
        XCTAssertEqual(store.servers.count, 1)

        store.removeServer(id: config.id)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testUpdateServer() {
        let store = makeStore()
        var config = MCPServerConfig(
            name: "Original",
            transport: .stdio(MCPStdioTransportConfig(command: "/bin/cat")),
            enabled: true,
            autoConnect: false
        )
        store.addServer(config)

        config.name = "Updated"
        config.enabled = false
        store.updateServer(config)

        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers[0].name, "Updated")
        XCTAssertFalse(store.servers[0].enabled)
    }

    func testMultipleServers() {
        let store = makeStore()
        let c1 = MCPServerConfig(
            name: "Server1",
            transport: .stdio(MCPStdioTransportConfig(command: "/bin/echo")),
            enabled: true,
            autoConnect: true
        )
        let c2 = MCPServerConfig(
            name: "Server2",
            transport: .http(MCPHTTPTransportConfig(url: "http://localhost:9090", apiKey: "key123")),
            enabled: false,
            autoConnect: false
        )
        store.addServer(c1)
        store.addServer(c2)

        XCTAssertEqual(store.servers.count, 2)
        XCTAssertEqual(store.servers[0].name, "Server1")
        XCTAssertEqual(store.servers[1].name, "Server2")
    }

    func testRemoveNonexistentServerIsNoOp() {
        let store = makeStore()
        let config = MCPServerConfig(
            name: "Keep",
            transport: .stdio(MCPStdioTransportConfig(command: "/bin/echo")),
            enabled: true,
            autoConnect: false
        )
        store.addServer(config)
        store.removeServer(id: UUID()) // Non-existent ID
        XCTAssertEqual(store.servers.count, 1)
    }

    func testTransportConfigCodable() throws {
        let stdioConfig = MCPServerConfig(
            name: "Stdio",
            transport: .stdio(MCPStdioTransportConfig(command: "/bin/echo", args: ["hello"], env: ["FOO": "BAR"])),
            enabled: true,
            autoConnect: true
        )
        let httpConfig = MCPServerConfig(
            name: "HTTP",
            transport: .http(MCPHTTPTransportConfig(url: "https://api.example.com", apiKey: "secret")),
            enabled: false,
            autoConnect: false
        )

        let data = try JSONEncoder().encode([stdioConfig, httpConfig])
        let decoded = try JSONDecoder().decode([MCPServerConfig].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "Stdio")
        XCTAssertEqual(decoded[1].name, "HTTP")

        if case .stdio(let sc) = decoded[0].transport {
            XCTAssertEqual(sc.command, "/bin/echo")
            XCTAssertEqual(sc.args, ["hello"])
            XCTAssertEqual(sc.env["FOO"], "BAR")
        } else {
            XCTFail("Expected stdio transport")
        }

        if case .http(let hc) = decoded[1].transport {
            XCTAssertEqual(hc.url, "https://api.example.com")
            XCTAssertEqual(hc.apiKey, "secret")
        } else {
            XCTFail("Expected http transport")
        }
    }
}
