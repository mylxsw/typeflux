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
        isError: false
    )
    var shouldFailConnect = false
    var connected = false

    var serverInfo: MCPConnectionInfo? {
        connected ? MCPConnectionInfo(
            name: "MockServer",
            protocolVersion: "2024-11-05",
            capabilities: MCPServerCapabilities(tools: nil)
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

    var shouldFailListTools = false

    func setMockTools(_ tools: [MCPToolDefinition], failing: Bool = false) {
        mockTools = tools
        shouldFailListTools = failing
    }

    func disconnect() async {
        disconnectCallCount += 1
        connected = false
    }

    func listTools() async throws -> [MCPToolDefinition] {
        guard connected else { throw MCPClientError.notConnected }
        listToolsCallCount += 1
        if shouldFailListTools { throw MCPClientError.invalidResponse("tools/list failed") }
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
                additionalProperties: nil
            )
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
            isError: true
        ))
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)

        let result = try await adapter.execute(arguments: #"{"query":"test"}"#)
        XCTAssertTrue(result.contains("\"error\""))
    }

    func testAdapterExecuteWithEmptyArgs() async throws {
        let client = MockMCPClient()
        try await client.connect()
        let toolDef = makeMockTool()
        let adapter = MCPToolAdapter(client: client, toolDef: toolDef)

        // Reject malformed JSON before invoking the MCP client.
        do { _ = try await adapter.execute(arguments: "not valid json"); XCTFail("Expected invalid input") }
        catch { XCTAssertTrue(error is MCPInputError) }
        let count = await client.callToolCallCount
        XCTAssertEqual(count, 0)
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
