import Foundation
@testable import Typeflux
import XCTest

final class MCPRegistryRecoveryTests: XCTestCase {
    func testDefaultStdioFactoryRetainsLaunchFailure() async throws {
        let server = MCPServerConfig(
            name: "Missing",
            transport: .stdio(MCPStdioTransportConfig(command: "missing-mcp-\(UUID())"))
        )
        let registry = MCPRegistry(settingsStore: store())
        do { try await registry.addServer(server); XCTFail("Expected launch failure") }
        catch MCPClientError.launchFailed {}
        let reason = await registry.lastConnectionError(for: server.id)
        XCTAssertTrue(reason?.contains("missing-mcp-") == true)
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }

    private func config(_ name: String = "Server", autoConnect: Bool = false, enabled: Bool = true) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http(MCPHTTPTransportConfig(url: "https://example.com/mcp")),
                        enabled: enabled, autoConnect: autoConnect)
    }

    private func store() -> MCPSettingsStore {
        MCPSettingsStore(defaults: UserDefaults(suiteName: "test.mcp.recovery.\(UUID())")!)
    }

    func testEnabledServerReconnectsAfterDisconnectAndReplacesTools() async {
        let server = config()
        let client = RegistryRecoveryClient()
        let registry = MCPRegistry(settingsStore: store(), clientFactory: { _ in client })
        await registry.connectEnabledServers([server])
        await registry.connectEnabledServers([server])
        var attempts = await client.connects
        XCTAssertEqual(attempts, 1)
        await client.disconnect()
        let disconnectedCount = await registry.connectedServerCount
        XCTAssertEqual(disconnectedCount, 0)
        await client.setTools(["new"])
        await registry.connectEnabledServers([server])
        attempts = await client.connects
        XCTAssertEqual(attempts, 2)
        let tools = await registry.registeredTools()
        XCTAssertEqual(tools.map(\.tool.toolDef.name), ["new"])
        let error = await registry.lastConnectionError(for: server.id)
        XCTAssertNil(error)
        await registry.removeServer(id: server.id)
    }

    func testAutoConnectReconnectsOnlyEnabledAutomaticServers() async {
        let settings = store()
        let automatic = config("Auto", autoConnect: true)
        settings.servers = [automatic, config("Manual"), config("Disabled", autoConnect: true, enabled: false)]
        let client = RegistryRecoveryClient()
        let registry = MCPRegistry(settingsStore: settings, clientFactory: { _ in client })
        await registry.connectAutoConnectServers()
        await client.disconnect()
        await registry.connectAutoConnectServers()
        let attempts = await client.connects
        let count = await registry.connectedServerCount
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(count, 1)
        await registry.removeServer(id: automatic.id)
    }

    func testFailuresRetainReasonAndCleanClientAndStaleTools() async throws {
        let server = config()
        let client = RegistryRecoveryClient()
        let registry = MCPRegistry(settingsStore: store(), clientFactory: { _ in client })
        await client.setFailure(connect: true)
        await registry.connectEnabledServers([server])
        var reason = await registry.lastConnectionError(for: server.id)
        XCTAssertTrue(reason?.contains("handshake rejected") == true)
        var count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
        await client.setFailure(connect: false)
        try await registry.addServer(server)
        await client.setFailure(list: true)
        do { try await registry.refreshTools(for: server.id); XCTFail("Expected failure") } catch {}
        let tools = await registry.registeredTools()
        XCTAssertTrue(tools.isEmpty)
        reason = await registry.lastConnectionError(for: server.id)
        XCTAssertTrue(reason?.contains("listing rejected") == true)
        await client.disconnect()
        await registry.connectEnabledServers([server])
        count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
        let disconnects = await client.disconnects
        XCTAssertGreaterThanOrEqual(disconnects, 3)
    }

    func testConcurrentRegistrationSharesOneConnect() async throws {
        let server = config()
        let client = RegistryRecoveryClient()
        let entered = expectation(description: "connecting")
        let gate = RegistryRecoveryGate()
        await client.pauseConnect(gate, entered: { entered.fulfill() })
        let registry = MCPRegistry(settingsStore: store(), clientFactory: { _ in client })
        let first = Task { try await registry.addServer(server) }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await registry.addServer(server) }
        await gate.release()
        try await first.value
        try await second.value
        let attempts = await client.connects
        XCTAssertEqual(attempts, 1)
        await registry.removeServer(id: server.id)
    }

    func testRemoveDuringConnectOrRefreshCannotRestoreTools() async throws {
        for duringConnect in [true, false] {
            let server = config()
            let client = RegistryRecoveryClient()
            let registry = MCPRegistry(settingsStore: store(), clientFactory: { _ in client })
            let entered = expectation(description: "operation suspended")
            let gate = RegistryRecoveryGate()
            if duringConnect {
                await client.pauseConnect(gate, entered: { entered.fulfill() })
            } else {
                try await registry.addServer(server)
                await client.pauseList(gate, entered: { entered.fulfill() })
            }
            let work = Task {
                if duringConnect {
                    try await registry.addServer(server)
                } else {
                    try await registry.refreshTools(for: server.id)
                }
            }
            await fulfillment(of: [entered], timeout: 2)
            await registry.removeServer(id: server.id)
            await gate.release()
            do { try await work.value; XCTFail("Expected removed operation to fail") } catch {}
            let tools = await registry.registeredTools()
            let count = await registry.connectedServerCount
            let clientConnected = await client.isConnected
            XCTAssertTrue(tools.isEmpty)
            XCTAssertEqual(count, 0)
            XCTAssertFalse(clientConnected)
        }
    }

    func testNotificationRefreshSurvivesRepeatedConnectAndFailureIsDiagnosable() async throws {
        let server = config()
        let client = RegistryRecoveryClient()
        let registry = MCPRegistry(settingsStore: store(), clientFactory: { _ in client })
        try await registry.addServer(server)
        try await registry.addServer(server)
        await client.setTools(["changed"])
        await client.notifyToolsChanged()
        let tools = await registry.registeredTools()
        XCTAssertEqual(tools.map(\.tool.toolDef.name), ["changed"])
        await client.setFailure(list: true)
        await client.notifyToolsChanged()
        let error = await registry.lastConnectionError(for: server.id)
        XCTAssertTrue(error?.contains("listing rejected") == true)
        await registry.removeServer(id: server.id)
        await client.notifyToolsChanged()
        let remaining = await registry.registeredTools()
        XCTAssertTrue(remaining.isEmpty)
    }
}

private actor RegistryRecoveryGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true; waiting?.resume(); waiting = nil
    }
}

private actor RegistryRecoveryClient: MCPClient {
    var serverInfo: MCPConnectionInfo? {
        nil
    }

    private(set) var isConnected = false
    private(set) var connects = 0
    private(set) var disconnects = 0
    private var tools = ["old"]
    private var failConnect = false
    private var failList = false
    private var connectGate: RegistryRecoveryGate?
    private var listGate: RegistryRecoveryGate?
    private var connectEntered: (() -> Void)?
    private var listEntered: (() -> Void)?
    private var changed: (@Sendable () async -> Void)?

    func setFailure(connect: Bool = false, list: Bool = false) {
        failConnect = connect; failList = list
    }

    func setTools(_ names: [String]) {
        tools = names
    }

    func pauseConnect(_ gate: RegistryRecoveryGate, entered: @escaping () -> Void) {
        connectGate = gate; connectEntered = entered
    }

    func pauseList(_ gate: RegistryRecoveryGate, entered: @escaping () -> Void) {
        listGate = gate; listEntered = entered
    }

    func connect() async throws {
        connects += 1
        connectEntered?()
        await connectGate?.wait()
        if failConnect {
            throw MCPClientError.invalidResponse("handshake rejected")
        }
        isConnected = true
    }

    func disconnect() {
        disconnects += 1; isConnected = false
    }

    func listTools() async throws -> [MCPToolDefinition] {
        listEntered?()
        await listGate?.wait()
        if failList {
            throw MCPClientError.invalidResponse("listing rejected")
        }
        return tools.map { MCPToolDefinition(
            name: $0,
            description: nil,
            inputSchema: MCPObjectSchema(
                type: "object",
                properties: nil,
                required: nil,
                description: nil,
                additionalProperties: nil
            )
        ) }
    }

    func callTool(name _: String, arguments _: [String: Any]) async throws -> MCPToolsCallResult {
        .init(
            content: [],
            isError: nil
        )
    }

    func ping() async throws {}
    func setToolsChangedHandler(_ handler: @escaping @Sendable () async -> Void) {
        changed = handler
    }

    func notifyToolsChanged() async {
        await changed?()
    }
}
