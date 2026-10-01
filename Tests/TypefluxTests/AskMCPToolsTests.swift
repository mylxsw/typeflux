import AppKit
@testable import Typeflux
import XCTest

/// MCP tool naming, registry ownership and result mapping used by Ask.
@MainActor
final class AskMCPToolsTests: XCTestCase {
    private func tool(_ name: String) -> MCPToolDefinition {
        MCPToolDefinition(
            name: name,
            description: "\(name) tool",
            inputSchema: MCPObjectSchema(type: "object", properties: nil, required: nil, description: nil, additionalProperties: nil)
        )
    }

    private func config(_ name: String) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http(MCPHTTPTransportConfig(url: "https://example.com/\(name)")))
    }

    private func registry(_ clients: [UUID: MockMCPClient]) -> MCPRegistry {
        MCPRegistry(
            settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "test.ask.mcp.\(UUID().uuidString)")!),
            clientFactory: { clients[$0.id]! }
        )
    }

    func testToolsWithTheSameNameOnTwoServersAreBothKept() async throws {
        let github = config("GitHub"), files = config("文件")
        let first = MockMCPClient(), second = MockMCPClient()
        await first.setMockTools([tool("search"), tool("issues")])
        await second.setMockTools([tool("search")])
        let registry = registry([github.id: first, files.id: second])
        try await registry.addServer(github)
        try await registry.addServer(files)

        let registered = await registry.registeredTools()
        XCTAssertEqual(registered.count, 3)
        let ambiguous = await registry.serverId(forToolName: "search")
        XCTAssertNil(ambiguous)
        let unique = await registry.serverId(forToolName: "issues")
        XCTAssertEqual(unique, github.id)
        let agentTools = await registry.allMCPTools()
        XCTAssertEqual(agentTools.count, 3)

        let names = AskLocalTools.mcpToolNames(registered).map(\.0)
        let fileSlug = String(files.id.uuidString.prefix(8)).lowercased()
        XCTAssertEqual(Set(names), ["mcp_issues", "mcp_GitHub_search", "mcp_\(fileSlug)_search"])

        await registry.removeServer(id: github.id)
        let remaining = await registry.registeredTools()
        XCTAssertEqual(remaining.map(\.tool.toolDef.name), ["search"])
        XCTAssertEqual(AskLocalTools.mcpToolNames(remaining).map(\.0), ["mcp_search"])
    }

    func testServerWhoseToolsCannotBeListedIsNotKept() async throws {
        let server = config("Broken")
        let client = MockMCPClient()
        await client.setMockTools([], failing: true)
        let registry = registry([server.id: client])
        do {
            try await registry.addServer(server)
            XCTFail("Expected tools/list failure")
        } catch {}
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
        let disconnects = await client.disconnectCallCount
        XCTAssertEqual(disconnects, 1)
    }

    func testInvalidOrOverlongNamesAreSkipped() {
        let client = MockMCPClient()
        let entries = ["ok_tool", "has space", String(repeating: "a", count: 61)].map {
            MCPRegisteredTool(serverId: UUID(), serverName: "S", tool: MCPToolAdapter(client: client, toolDef: tool($0)))
        }
        XCTAssertEqual(AskLocalTools.mcpToolNames(entries).map(\.0), ["mcp_ok_tool"])
        XCTAssertEqual(AskLocalTools.serverSlug("My Server!", id: UUID()), "My_Server")
        XCTAssertEqual(AskLocalTools.serverSlug(String(repeating: "x", count: 40), id: UUID()).count, 20)
    }

    func testDefinitionsExposeMCPToolsAndExecuteKeepsErrors() async throws {
        let server = config("Search")
        let client = MockMCPClient()
        await client.setMockTools([tool("lookup")])
        await client.setMockCallResult(MCPToolsCallResult(content: [MCPContentBlock(type: "text", text: "quota exceeded")], isError: true))
        let registry = registry([server.id: client])
        try await registry.addServer(server)
        let tools = AskLocalTools(registry: registry)

        let names = await tools.definitions(conversationId: nil).map(\.name)
        XCTAssertEqual(names, ["computer", "mcp_lookup"])
        let output = try await tools.execute(.init(id: "1", function: .init(name: "mcp_lookup", arguments: "{}")), conversationId: "c")
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.content, "quota exceeded")
    }

    func testOutputMapsTextResourcesAndImages() throws {
        let text = AskLocalTools.output(from: MCPToolsCallResult(content: [
            MCPContentBlock(type: "text", text: "line"),
            MCPContentBlock(type: "resource", resource: MCPEmbeddedResource(uri: "file:///a", mimeType: "text/plain", text: "file body"))
        ], isError: nil))
        XCTAssertEqual(text.content, "line\nfile body")
        XCTAssertFalse(text.isError)
        XCTAssertNil(text.image)

        let png = try Self.pngBase64(width: 3200, height: 1600)
        let image = AskLocalTools.output(from: MCPToolsCallResult(content: [
            MCPContentBlock(type: "image", data: "not an image", mimeType: "image/png"),
            MCPContentBlock(type: "image", data: png, mimeType: "image/png"),
            MCPContentBlock(type: "image", data: png, mimeType: "image/png")
        ], isError: false))
        let dataURL = try XCTUnwrap(image.image)
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))
        let jpeg = try XCTUnwrap(Data(base64Encoded: String(dataURL.dropFirst("data:image/jpeg;base64,".count))))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 1600)
        XCTAssertEqual(image.content, "[2 image(s) from the tool could not be attached]")

        let invalid = AskLocalTools.output(from: MCPToolsCallResult(content: [MCPContentBlock(type: "image", data: "@@@")], isError: false))
        XCTAssertNil(invalid.image)
        XCTAssertEqual(invalid.content, "[1 image(s) from the tool could not be attached]")

        let onlyImage = AskLocalTools.output(from: MCPToolsCallResult(content: [MCPContentBlock(type: "image", data: png)], isError: false))
        XCTAssertEqual(onlyImage.content, "The tool returned an image.")
        let empty = AskLocalTools.output(from: MCPToolsCallResult(content: [], isError: true))
        XCTAssertEqual(empty.content, "The tool returned no content.")
        XCTAssertTrue(empty.isError)

        let long = AskLocalTools.output(from: MCPToolsCallResult(content: [MCPContentBlock(type: "text", text: String(repeating: "x", count: 70000))], isError: false))
        XCTAssertEqual(long.content.count, 60000)
    }

    func testAgentAdapterStillReportsErrorsAndResourceText() async throws {
        let client = MockMCPClient()
        try await client.connect()
        await client.setMockCallResult(MCPToolsCallResult(content: [
            MCPContentBlock(type: "image", data: "abc"),
            MCPContentBlock(type: "resource", resource: MCPEmbeddedResource(uri: nil, mimeType: nil, text: "embedded"))
        ], isError: true))
        let output = try await MCPToolAdapter(client: client, toolDef: tool("t")).execute(arguments: "{}")
        XCTAssertEqual(output, #"{"error":"embedded"}"#)
    }

    func testToolPagesStopOnRepeatedCursorAndPageLimit() async throws {
        var calls: [String?] = []
        let repeated = try await collectMCPToolPages { cursor in
            calls.append(cursor)
            return MCPToolsListResult(tools: [self.tool("t\(calls.count)")], nextCursor: "same")
        }
        XCTAssertEqual(repeated.map(\.name), ["t1", "t2"])
        XCTAssertEqual(calls, [nil, "same"])

        var pages = 0
        let limited = try await collectMCPToolPages(maxPages: 3) { _ in
            pages += 1
            return MCPToolsListResult(tools: [self.tool("p\(pages)")], nextCursor: "c\(pages)")
        }
        XCTAssertEqual(limited.count, 3)
    }

    func testJSONRPCErrorIsReportedInsteadOfMissingResult() {
        let message = MCPJsonRPCMessage(id: .string("1"), error: MCPErrorDetail(code: -32602, message: "bad args", data: nil))
        XCTAssertThrowsError(try message.decodeToolsCallResult()) { error in
            XCTAssertEqual(error.localizedDescription, "MCP server error -32602: bad args")
        }
        XCTAssertThrowsError(try MCPJsonRPCMessage(id: .string("2")).decodeToolsListResult()) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid MCP response: No result in message")
        }
        XCTAssertEqual(MCPClientError.timedOut.localizedDescription, "The MCP server did not respond in time.")
        XCTAssertEqual(MCPClientError.launchFailed("npx").localizedDescription, "Could not start the MCP server command: npx")
        let cancel = MCPJsonRPCMessage.cancelledNotification(requestId: .string("7"), reason: "Request timed out")
        XCTAssertEqual(cancel.method, "notifications/cancelled")
        XCTAssertNil(cancel.id)
        XCTAssertEqual(cancel.params?["requestId"]?.value as? String, "7")
        XCTAssertEqual(MCPJsonRPCMessage.toolsListRequest(id: .string("3"), cursor: "abc").params?["cursor"]?.value as? String, "abc")
    }

    private static func pngBase64(width: Int, height: Int) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:])).base64EncodedString()
    }
}
