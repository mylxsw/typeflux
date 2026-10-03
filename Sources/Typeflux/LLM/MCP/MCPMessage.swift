import Foundation
import CoreFoundation

// MARK: - AnyCodable

/// Type-erased Codable value for handling arbitrary JSON data.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable: unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { try container.encode(number.boolValue) }
            else if ["f", "d"].contains(String(cString: number.objCType)) { try container.encode(number.doubleValue) }
            else { try container.encode(number.int64Value) }
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "AnyCodable: unsupported type \(type(of: value))"
            ))
        }
    }
}

// MARK: - MCPMessageId

enum MCPMessageId: Codable, Equatable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let num = try? container.decode(Int.self) {
            self = .number(num)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid MCPMessageId")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(s): try container.encode(s)
        case let .number(n): try container.encode(n)
        }
    }

    var stringValue: String {
        switch self {
        case let .string(s): s
        case let .number(n): String(n)
        }
    }
}

// MARK: - MCP Info Structures

struct MCPClientInfo: Codable {
    let name: String
    let version: String
}

struct MCPServerInfo: Codable {
    let name: String
    let version: String
}

struct MCPToolsCapability: Codable {
    let listChanged: Bool?
}

struct MCPServerCapabilities: Codable {
    let tools: MCPToolsCapability?
}

// MARK: - Initialize

struct MCPInitializeParams: Codable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let clientInfo: MCPClientInfo
}

struct MCPInitializeResult: Codable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo?
}

// MARK: - Tools List

struct MCPToolsListParams: Codable {
    let cursor: String?
    init(cursor: String? = nil) {
        self.cursor = cursor
    }
}

/// Keep every keyword, including root combinators, definitions and vendor metadata.
struct MCPObjectSchema: Codable {
    let raw: [String: AnyCodable]
    var type: String? { raw["type"]?.value as? String }
    var properties: [String: AnyCodable]? { (raw["properties"]?.value as? [String: Any])?.mapValues(AnyCodable.init) }
    var required: [String]? { raw["required"]?.value as? [String] }
    var description: String? { raw["description"]?.value as? String }
    var additionalProperties: AnyCodable? { raw["additionalProperties"] }

    init(type: String?, properties: [String: AnyCodable]?, required: [String]?, description: String?, additionalProperties: AnyCodable?) {
        var value: [String: AnyCodable] = [:]
        if let type { value["type"] = AnyCodable(type) }
        if let properties { value["properties"] = AnyCodable(properties.mapValues(\.value)) }
        if let required { value["required"] = AnyCodable(required) }
        if let description { value["description"] = AnyCodable(description) }
        value["additionalProperties"] = additionalProperties
        raw = value
    }
    init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode([String: AnyCodable].self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}

/// Behavior hints from the server (MCP 2025-03-26). Untrusted: they only tune approval prompts.
struct MCPToolAnnotations: Codable, Equatable {
    var readOnlyHint: Bool?
    var destructiveHint: Bool?
}

struct MCPToolDefinition: Codable {
    let name: String
    let description: String?
    let inputSchema: MCPObjectSchema
    var annotations: MCPToolAnnotations? = nil

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, annotations
    }
}

struct MCPToolsListResult: Codable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?
}

// MARK: - Tools Call

struct MCPToolsCallParams: Codable {
    let name: String
    let arguments: [String: AnyCodable]?
}

/// An opaque MCP object with convenience accessors. Unknown keys survive encoding.
struct MCPContentBlock: Codable {
    let raw: JSONValue
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] ?? [:] }
    var type: String { object["type"] as? String ?? "unknown" }
    var text: String? { object["text"] as? String }
    var data: String? { object["data"] as? String }
    var mimeType: String? { object["mimeType"] as? String }
    var resource: MCPEmbeddedResource? {
        guard let value = object["resource"], let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MCPEmbeddedResource.self, from: data)
    }
    init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil, resource: MCPEmbeddedResource? = nil) {
        var value: [String: Any] = ["type": type]
        value["text"] = text; value["data"] = data; value["mimeType"] = mimeType
        if let resource { value["resource"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(resource)) }
        raw = JSONValue(data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
    }
    init(from decoder: Decoder) throws { raw = try JSONValue(from: decoder) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

struct MCPEmbeddedResource: Codable {
    let uri: String?
    let mimeType: String?
    let text: String?
}

struct MCPToolsCallResult: Codable {
    let content: [MCPContentBlock]
    let isError: Bool?
    var structuredContent: JSONValue? = nil
    var metadata: JSONValue? = nil
    enum CodingKeys: String, CodingKey { case content, isError, structuredContent; case metadata = "_meta" }
    init(content: [MCPContentBlock], isError: Bool?, structuredContent: JSONValue? = nil, metadata: JSONValue? = nil) {
        self.content = content; self.isError = isError; self.structuredContent = structuredContent; self.metadata = metadata
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent([MCPContentBlock].self, forKey: .content) ?? []
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        structuredContent = try c.decodeIfPresent(JSONValue.self, forKey: .structuredContent)
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }
    var textContent: String { content.compactMap { $0.text ?? $0.resource?.text }.joined(separator: "\n") }
}

// MARK: - Error

struct MCPErrorDetail: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - MCPJsonRPCMessage

// Flexible message structure using raw JSON for params/result

struct MCPJsonRPCMessage: Codable {
    let jsonrpc: String
    let id: MCPMessageId?
    let method: String?
    let params: [String: AnyCodable]?
    let result: [String: AnyCodable]?
    let error: MCPErrorDetail?

    init(
        jsonrpc: String = "2.0",
        id: MCPMessageId? = nil,
        method: String? = nil,
        params: [String: AnyCodable]? = nil,
        result: [String: AnyCodable]? = nil,
        error: MCPErrorDetail? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

// MARK: - Typed message constructors

extension MCPJsonRPCMessage {
    /// Create an initialize request
    static func initializeRequest(id: MCPMessageId, params: MCPInitializeParams) throws -> MCPJsonRPCMessage {
        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let paramsDict = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        return MCPJsonRPCMessage(jsonrpc: "2.0", id: id, method: "initialize", params: paramsDict)
    }

    /// Create an initialized notification
    static func initializedNotification() -> MCPJsonRPCMessage {
        MCPJsonRPCMessage(jsonrpc: "2.0", id: nil, method: "notifications/initialized", params: nil)
    }

    /// Create a tools/list request
    static func toolsListRequest(id: MCPMessageId, cursor: String? = nil) -> MCPJsonRPCMessage {
        MCPJsonRPCMessage(jsonrpc: "2.0", id: id, method: "tools/list", params: cursor.map { ["cursor": AnyCodable($0)] } ?? [:])
    }

    /// Create a cancellation notification for an abandoned request
    static func cancelledNotification(requestId: MCPMessageId, reason: String) -> MCPJsonRPCMessage {
        MCPJsonRPCMessage(jsonrpc: "2.0", id: nil, method: "notifications/cancelled",
                          params: ["requestId": AnyCodable(requestId.stringValue), "reason": AnyCodable(reason)])
    }

    /// Create a tools/call request
    static func toolsCallRequest(id: MCPMessageId, params: MCPToolsCallParams) throws -> MCPJsonRPCMessage {
        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let paramsDict = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        return MCPJsonRPCMessage(jsonrpc: "2.0", id: id, method: "tools/call", params: paramsDict)
    }

    /// Parse result as MCPInitializeResult
    func decodeInitializeResult() throws -> MCPInitializeResult {
        guard let result else {
            if let error { throw MCPClientError.serverError(code: error.code, message: error.message) }
            throw MCPClientError.invalidResponse("No result in message")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(MCPInitializeResult.self, from: data)
    }

    /// Parse result as MCPToolsListResult
    func decodeToolsListResult() throws -> MCPToolsListResult {
        guard let result else {
            if let error { throw MCPClientError.serverError(code: error.code, message: error.message) }
            throw MCPClientError.invalidResponse("No result in message")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(MCPToolsListResult.self, from: data)
    }

    /// Parse result as MCPToolsCallResult
    func decodeToolsCallResult() throws -> MCPToolsCallResult {
        guard let result else {
            if let error { throw MCPClientError.serverError(code: error.code, message: error.message) }
            throw MCPClientError.invalidResponse("No result in message")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(MCPToolsCallResult.self, from: data)
    }
}

// MARK: - MCPClientError

enum MCPClientError: LocalizedError {
    case notConnected
    case invalidResponse(String)
    case serverError(code: Int, message: String)
    case encodingError(String)
    case timedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "MCP client is not connected."
        case let .invalidResponse(msg):
            "Invalid MCP response: \(msg)"
        case let .serverError(code, message):
            "MCP server error \(code): \(message)"
        case let .encodingError(msg):
            "MCP encoding error: \(msg)"
        case .timedOut:
            "The MCP server did not respond in time."
        case let .launchFailed(command):
            "Could not start the MCP server command: \(command)"
        }
    }
}
