import XCTest
@testable import Typeflux

final class MCPMessageTests: XCTestCase {

    func testMCPMessageIdStringCodable() throws {
        let id = MCPMessageId.string("test-id")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(MCPMessageId.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testMCPMessageIdNumberCodable() throws {
        let id = MCPMessageId.number(42)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(MCPMessageId.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testMCPMessageIdStringValue() {
        XCTAssertEqual(MCPMessageId.string("abc").stringValue, "abc")
        XCTAssertEqual(MCPMessageId.number(7).stringValue, "7")
    }

    func testMCPJsonRPCMessageCodable() throws {
        let message = MCPJsonRPCMessage(
            jsonrpc: "2.0",
            id: .string("1"),
            method: "initialize",
            params: nil,
            result: nil,
            error: nil
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(MCPJsonRPCMessage.self, from: data)
        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.method, "initialize")
        XCTAssertEqual(decoded.id, .string("1"))
        XCTAssertNil(decoded.error)
    }

    func testMCPToolDefinitionCodable() throws {
        let jsonStr = """
        {
            "name": "my_tool",
            "description": "Does something useful",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"}
                },
                "required": ["query"]
            }
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let tool = try JSONDecoder().decode(MCPToolDefinition.self, from: data)
        XCTAssertEqual(tool.name, "my_tool")
        XCTAssertEqual(tool.description, "Does something useful")
        XCTAssertEqual(tool.inputSchema.required, ["query"])
    }

    func testMCPToolsCallResultCodable() throws {
        let jsonStr = """
        {
            "content": [
                {"type": "text", "text": "Hello from tool"},
                {"type": "text", "text": " world"}
            ],
            "isError": false
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPToolsCallResult.self, from: data)
        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.content[0].text, "Hello from tool")
        XCTAssertEqual(result.content[1].text, " world")
        XCTAssertEqual(result.isError, false)
    }

    func testAnyCodableString() throws {
        let value = AnyCodable("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testAnyCodableInt() throws {
        let value = AnyCodable(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testAnyCodableBool() throws {
        let value = AnyCodable(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testAnyCodableArray() throws {
        let value = AnyCodable(["a", "b", "c"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? [String], ["a", "b", "c"])
    }

    func testAnyCodableDict() throws {
        let value = AnyCodable(["key": "val"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.value as? [String: String]
        XCTAssertEqual(dict?["key"], "val")
    }

    func testInitializeRequestConstruction() throws {
        let params = MCPInitializeParams(
            protocolVersion: "2024-11-05",
            capabilities: MCPServerCapabilities(tools: MCPToolsCapability(listChanged: nil)),
            clientInfo: MCPClientInfo(name: "Test", version: "1.0")
        )
        let msg = try MCPJsonRPCMessage.initializeRequest(id: .string("1"), params: params)
        XCTAssertEqual(msg.jsonrpc, "2.0")
        XCTAssertEqual(msg.method, "initialize")
        XCTAssertEqual(msg.id, .string("1"))
        XCTAssertNotNil(msg.params)
    }

    func testMCPInitializeResultDecoding() throws {
        let jsonStr = """
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "TestServer", "version": "2.0"}
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPInitializeResult.self, from: data)
        XCTAssertEqual(result.protocolVersion, "2024-11-05")
        XCTAssertEqual(result.serverInfo?.name, "TestServer")
    }
}

// MARK: - Extended MCPMessage tests

extension MCPMessageTests {

    // MARK: - MCPMessageId

    func testMCPMessageIdEqualityForSameString() {
        XCTAssertEqual(MCPMessageId.string("a"), MCPMessageId.string("a"))
    }

    func testMCPMessageIdInequalityBetweenStringAndNumber() {
        XCTAssertNotEqual(MCPMessageId.string("1"), MCPMessageId.number(1))
    }

    func testMCPMessageIdStringValueForNumber() {
        XCTAssertEqual(MCPMessageId.number(99).stringValue, "99")
    }

    func testMCPMessageIdStringValueForString() {
        XCTAssertEqual(MCPMessageId.string("req-007").stringValue, "req-007")
    }

    // MARK: - AnyCodable

    func testAnyCodableEncodesNull() throws {
        let value = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(value)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "null")
    }

    func testAnyCodableEncodesBool() throws {
        let value = AnyCodable(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testAnyCodableEncodesInt() throws {
        let value = AnyCodable(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testAnyCodableEncodesDouble() throws {
        let value = AnyCodable(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let doubleValue = try XCTUnwrap(decoded.value as? Double)
        XCTAssertEqual(doubleValue, 3.14, accuracy: 0.001)
    }

    func testAnyCodableEncodesString() throws {
        let value = AnyCodable("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testAnyCodableEncodesArray() throws {
        let value = AnyCodable([1, 2, 3])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? [Int], [1, 2, 3])
    }

    func testAnyCodableEncodesDictionary() throws {
        let value = AnyCodable(["key": "val"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.value as? [String: Any]
        XCTAssertEqual(dict?["key"] as? String, "val")
    }

    func testAnyCodableDecodesNullFromJSON() throws {
        let data = Data("null".utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testAnyCodableDecodesBoolFromJSON() throws {
        let data = Data("false".utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, false)
    }

    func testAnyCodableDecodesNestedStructure() throws {
        let json = """
        {"name": "test", "count": 5, "active": true, "items": ["a", "b"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let dict = decoded.value as? [String: Any]
        XCTAssertEqual(dict?["name"] as? String, "test")
        XCTAssertEqual(dict?["count"] as? Int, 5)
        XCTAssertEqual(dict?["active"] as? Bool, true)
    }
}
