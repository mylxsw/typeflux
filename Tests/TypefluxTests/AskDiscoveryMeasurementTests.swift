import Foundation
@testable import Typeflux
import XCTest

/// Offline harness: timings describe repeated local assembly, not live servers.
@MainActor
final class AskDiscoveryMeasurementTests: XCTestCase {
    func testRepeatedDefinitionAssemblyAndInvalidation() async throws {
        for count in [0, 10, 50] {
            for bytes in [128, 4096] {
                let domain = "discovery-\(UUID())"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
                defer { defaults.removePersistentDomain(forName: domain) }
                let settings = MCPSettingsStore(defaults: defaults)
                let client = MockMCPClient()
                let server = MCPServerConfig(name: "Fixture", transport: .http(.init(url: "https://fixture.invalid")))
                settings.servers = [server]
                let registry = MCPRegistry(settingsStore: settings, clientFactory: { _ in client })
                let schemas = (0..<count).map { index in
                    MCPToolDefinition(name: "tool_\(index)", description: "Offline fixture",
                        inputSchema: MCPObjectSchema(type: "object", properties: ["query": AnyCodable([
                            "type": "string", "description": String(repeating: "s", count: bytes)
                        ])], required: ["query"], description: nil, additionalProperties: nil))
                }
                await client.setMockTools(schemas)
                let tools = AskLocalTools(registry: registry)
                tools.runningBundleIdentifiers = { [] }
                let disconnected = await tools.definitions(conversationId: nil)
                XCTAssertFalse(disconnected.contains { $0.name.hasPrefix("mcp_") })
                let connectionStart = Date()
                // Explicit selection uses the same enabled-server entry point.
                await registry.connectEnabledServers([server])
                let connectionMS = Date().timeIntervalSince(connectionStart) * 1000
                var assemblyMS = 0.0, serializationMS = 0.0, schemaSortMS = 0.0, registryMS = 0.0, promptBytes = 0, schemaBytes = 0
                for _ in 0..<20 {
                    let registryStart = Date()
                    let registered = await registry.registeredTools()
                    registryMS += Date().timeIntervalSince(registryStart) * 1000
                    let schemaStart = Date()
                    for (_, entry) in AskLocalTools.mcpToolNames(registered) {
                        _ = try JSONSerialization.data(withJSONObject: entry.tool.definition.inputSchema.jsonObject, options: .sortedKeys)
                    }
                    schemaSortMS += Date().timeIntervalSince(schemaStart) * 1000
                    let start = Date()
                    let definitions = await tools.definitions(conversationId: nil)
                    assemblyMS += Date().timeIntervalSince(start) * 1000
                    let encodeStart = Date()
                    let data = try JSONEncoder().encode(definitions)
                    serializationMS += Date().timeIntervalSince(encodeStart) * 1000
                    promptBytes = data.count
                    schemaBytes = definitions.reduce(0) { $0 + $1.parameters.data.count }
                    XCTAssertEqual(definitions.filter { $0.name.hasPrefix("mcp_") }.count, count)
                }
                let listings = await client.listToolsCallCount
                XCTAssertEqual(listings, 1, "Repeated definitions must use the registry's cached tools")
                print("DISCOVERY count=\(count) field_bytes=\(bytes) repetitions=20 connection_ms=\(connectionMS) assembly_mean_ms=\(assemblyMS / 20) schema_sort_mean_ms=\(schemaSortMS / 20) registry_read_mean_ms=\(registryMS / 20) prompt_serialization_mean_ms=\(serializationMS / 20) schema_bytes=\(schemaBytes) prompt_bytes=\(promptBytes)")
                await client.setMockTools([])
                try await registry.refreshTools(for: server.id)
                let refreshed = await tools.definitions(conversationId: nil)
                XCTAssertFalse(refreshed.contains { $0.name.hasPrefix("mcp_") })
                await registry.removeServer(id: server.id)
                var disabled = server
                disabled.enabled = false
                settings.updateServer(disabled)
                await registry.connectAutoConnectServers()
                let connections = await client.connectCallCount
                XCTAssertEqual(connections, 1)
                let afterRemoval = await tools.definitions(conversationId: nil)
                XCTAssertFalse(afterRemoval.contains { $0.name.hasPrefix("mcp_") })
            }
        }
    }
}

extension AskDiscoveryMeasurementTests {
    func testHeldAutoConnectWaitIsSeparateFromCachedDefinitionRead() async throws {
        let domain = "held-discovery-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = MCPSettingsStore(defaults: defaults)
        let server = MCPServerConfig(name: "Held", transport: .http(.init(url: "https://held.invalid")), autoConnect: true)
        settings.servers = [server]
        let client = HeldDiscoveryClient()
        let registry = MCPRegistry(settingsStore: settings, clientFactory: { _ in client })
        let tools = AskLocalTools(registry: registry)
        tools.runningBundleIdentifiers = { [] }
        let start = Date()
        let task = Task { await tools.definitions(conversationId: nil) }
        var events = client.entered.makeAsyncIterator()
        _ = await events.next()
        let readStart = Date()
        let cached = await registry.registeredTools()
        let readMS = Date().timeIntervalSince(readStart) * 1000
        XCTAssertTrue(cached.isEmpty)
        let holdMS = Date().timeIntervalSince(start) * 1000
        await client.release()
        let definitions = await task.value
        XCTAssertTrue(definitions.contains { $0.name == "mcp_before" })
        await client.changeTools()
        let refreshed = await tools.definitions(conversationId: nil)
        XCTAssertFalse(refreshed.contains { $0.name == "mcp_before" })
        XCTAssertTrue(refreshed.contains { $0.name == "mcp_after" })
        print("DISCOVERY held_connection_gate_ms=\(holdMS) cached_registry_read_while_held_ms=\(readMS) total_definition_wait_ms=\(Date().timeIntervalSince(start) * 1000)")
        await registry.removeServer(id: server.id)
    }
}

private actor HeldDiscoveryClient: MCPClient {
    nonisolated let entered: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var held: CheckedContinuation<Void, Never>?
    private var connected = false
    private var name = "before"
    private var changed: (@Sendable () async -> Void)?
    init() { (entered, continuation) = AsyncStream.makeStream() }
    var serverInfo: MCPConnectionInfo? { nil }
    var isConnected: Bool { connected }
    func connect() async throws {
        await withCheckedContinuation { held = $0; continuation.yield(()) }
        connected = true
    }
    func release() { held?.resume(); held = nil }
    func disconnect() async { connected = false }
    func listTools() async throws -> [MCPToolDefinition] {
        [.init(name: name, description: "Offline fixture", inputSchema: .init(type: "object", properties: nil,
            required: nil, description: nil, additionalProperties: nil))]
    }
    func callTool(name _: String, arguments _: [String: Any]) async throws -> MCPToolsCallResult { throw MCPClientError.notConnected }
    func ping() async throws {}
    func setToolsChangedHandler(_ handler: @escaping @Sendable () async -> Void) async { changed = handler }
    func changeTools() async { name = "after"; await changed?() }
}
