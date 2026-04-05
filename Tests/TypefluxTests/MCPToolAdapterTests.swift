@testable import Typeflux
import XCTest

// MARK: - Mock MCPClient

actor MockMCPClient: MCPClient {
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var listToolsCallCount = 0
    private(set) var callToolCallCount = 0

    var mockTools: [MCPToolDefinition] = []
    var mockCallResult: MCPToolsCallResult = .init(
        content: [MCPContentBlock(type: "text", text: "mock result")],
        isError: false,
    )
    var shouldFailConnect = false
    var connected = false

    var serverInfo: MCPConnectionInfo? {
        connected ? MCPConnectionInfo(
            name: "MockServer",
            protocolVersion: "2024-11-05",
            capabilities: MCPServerCapabilities(tools: nil),
        ) : nil
    }

    var isConnected: Bool {
        connected
    }

    func connect() async throws {
        connectCallCount += 1
        if shouldFailConnect {
            throw MCPClientError.notConnected
        }
        connected = true
    }

    func setMockCallResult(_ result: MCPToolsCallResult) {
        mockCallResult = result
    }

    func disconnect() async {
        disconnectCallCount += 1
        connected = false
    }

    func listTools() async throws -> [MCPToolDefinition] {
        guard connected else { throw MCPClientError.notConnected }
        listToolsCallCount += 1
        return mockTools
    }

    func callTool(name _: String, arguments _: [String: Any]) async throws -> MCPToolsCallResult {
        guard connected else { throw MCPClientError.notConnected }
        callToolCallCount += 1
        return mockCallResult
    }

    func ping() async throws {
        guard connected else { throw MCPClientError.notConnected }
    }
}

// MARK: - MCPToolAdapterTests

final class MCPToolAdapterTests: XCTestCase {
    private func makeMockTool() -> MCPToolDefinition {
        MCPToolDefinition(
            name: "mock_tool",
            description: "A mock tool for testing",
            inputSchema: MCPObjectSchema(
                type: "object",
                properties: ["query": AnyCodable(["type": "string"])],
                required: ["query"],
                description: nil,
                additionalProperties: nil,
            ),
        )
    }

    func testAdapterDefinitionName() async throws {
        let client = MockMCPClient()
        try await client.connect()
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)
        XCTAssertEqual(adapter.definition.name, "mock_tool")
    }

    func testAdapterDefinitionDescription() async throws {
        let client = MockMCPClient()
        try await client.connect()
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)
        XCTAssertEqual(adapter.definition.description, "A mock tool for testing")
    }

    func testAdapterExecuteSuccess() async throws {
        let client = MockMCPClient()
        try await client.connect()
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)

        let result = try await adapter.execute(arguments: #"{"query": "test"}"#)
        XCTAssertTrue(result.contains("mock result"))
        XCTAssertFalse(result.contains("\"error\""))
        let callCount = await client.callToolCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testAdapterExecuteWithErrorResult() async throws {
        let client = MockMCPClient()
        try await client.connect()
        await client.setMockCallResult(MCPToolsCallResult(
            content: [MCPContentBlock(type: "text", text: "something failed")],
            isError: true,
        ))
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)

        let result = try await adapter.execute(arguments: "{}")
        XCTAssertTrue(result.contains("\"error\""))
    }

    func testAdapterExecuteWithEmptyArgs() async throws {
        let client = MockMCPClient()
        try await client.connect()
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)

        // Invalid JSON should still work (uses empty dict fallback)
        let result = try await adapter.execute(arguments: "not valid json")
        XCTAssertFalse(result.isEmpty)
    }

    func testAdapterSchemaConversion() async throws {
        let client = MockMCPClient()
        try await client.connect()
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)

        let schema = adapter.definition.inputSchema
        XCTAssertEqual(schema.name, "mock_tool")
        let jsonObj = schema.jsonObject
        XCTAssertEqual(jsonObj["type"] as? String, "object")
    }
}

// MARK: - AgentErrorTests

final class AgentErrorTests: XCTestCase {
    func testMaxStepsExceededDescription() {
        let error = AgentError.maxStepsExceeded
        XCTAssertEqual(error.errorDescription, "Agent reached maximum execution steps without terminating.")
    }

    func testToolNotFoundDescription() {
        let error = AgentError.toolNotFound(name: "my_tool")
        XCTAssertTrue(error.errorDescription?.contains("my_tool") == true)
    }

    func testToolExecutionFailedDescription() {
        let error = AgentError.toolExecutionFailed(name: "tool", reason: "timeout")
        XCTAssertTrue(error.errorDescription?.contains("tool") == true)
        XCTAssertTrue(error.errorDescription?.contains("timeout") == true)
    }

    func testMCPConnectionFailedDescription() {
        let error = AgentError.mcpConnectionFailed(serverName: "server1", reason: "refused")
        XCTAssertTrue(error.errorDescription?.contains("server1") == true)
        XCTAssertTrue(error.errorDescription?.contains("refused") == true)
    }

    func testMCPServerNotFoundDescription() {
        let id = UUID()
        let error = AgentError.mcpServerNotFound(id: id)
        XCTAssertTrue(error.errorDescription?.contains(id.uuidString) == true)
    }

    func testInvalidAgentStateDescription() {
        let error = AgentError.invalidAgentState(reason: "bad state")
        XCTAssertTrue(error.errorDescription?.contains("bad state") == true)
    }

    func testLLMConnectionFailedDescription() {
        let error = AgentError.llmConnectionFailed(reason: "network error")
        XCTAssertTrue(error.errorDescription?.contains("network error") == true)
    }

    func testEquality() {
        XCTAssertEqual(AgentError.maxStepsExceeded, AgentError.maxStepsExceeded)
        XCTAssertEqual(AgentError.toolNotFound(name: "x"), AgentError.toolNotFound(name: "x"))
        XCTAssertNotEqual(AgentError.toolNotFound(name: "x"), AgentError.toolNotFound(name: "y"))
        XCTAssertNotEqual(AgentError.maxStepsExceeded, AgentError.toolNotFound(name: "x"))
    }
}
