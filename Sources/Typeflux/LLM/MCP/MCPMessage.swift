import Foundation

// MARK: - AnyCodable

/// 类型擦除的 Codable 值，用于处理任意 JSON 数据
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

enum MCPMessageId: Codable, Sendable, Equatable {
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
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        }
    }
}

// MARK: - MCP Info Structures

struct MCPClientInfo: Codable, Sendable {
    let name: String
    let version: String
}

struct MCPServerInfo: Codable, Sendable {
    let name: String
    let version: String
}

struct MCPToolsCapability: Codable, Sendable {
    let listChanged: Bool?
}

struct MCPServerCapabilities: Codable, Sendable {
    let tools: MCPToolsCapability?
}

// MARK: - Initialize

struct MCPInitializeParams: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let clientInfo: MCPClientInfo
}

struct MCPInitializeResult: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo?
}

// MARK: - Tools List

struct MCPToolsListParams: Codable, Sendable {
    let cursor: String?
    init(cursor: String? = nil) { self.cursor = cursor }
}

struct MCPObjectSchema: Codable, Sendable {
    let type: String?
    let properties: [String: AnyCodable]?
    let required: [String]?
    let description: String?
    let additionalProperties: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case type, properties, required, description, additionalProperties
    }
}

struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String?
    let inputSchema: MCPObjectSchema

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }
}

struct MCPToolsListResult: Codable, Sendable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?
}

// MARK: - Tools Call

struct MCPToolsCallParams: Codable, Sendable {
    let name: String
    let arguments: [String: AnyCodable]?
}

struct MCPContentBlock: Codable, Sendable {
    let type: String
    let text: String?
}

struct MCPToolsCallResult: Codable, Sendable {
    let content: [MCPContentBlock]
    let isError: Bool?
}

// MARK: - Error

struct MCPErrorDetail: Codable, Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - MCPJsonRPCMessage
// Flexible message structure using raw JSON for params/result

struct MCPJsonRPCMessage: Codable, Sendable {
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
    static func toolsListRequest(id: MCPMessageId) -> MCPJsonRPCMessage {
        MCPJsonRPCMessage(jsonrpc: "2.0", id: id, method: "tools/list", params: [:])
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
        guard let result = result else {
            throw MCPClientError.invalidResponse("No result in message")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(MCPInitializeResult.self, from: data)
    }

    /// Parse result as MCPToolsListResult
    func decodeToolsListResult() throws -> MCPToolsListResult {
        guard let result = result else {
            throw MCPClientError.invalidResponse("No result in message")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(MCPToolsListResult.self, from: data)
    }

    /// Parse result as MCPToolsCallResult
    func decodeToolsCallResult() throws -> MCPToolsCallResult {
        guard let result = result else {
            throw MCPClientError.invalidResponse("No result in message")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(MCPToolsCallResult.self, from: data)
    }
}

// MARK: - MCPClientError

enum MCPClientError: LocalizedError, Sendable {
    case notConnected
    case invalidResponse(String)
    case serverError(code: Int, message: String)
    case encodingError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "MCP client is not connected."
        case .invalidResponse(let msg):
            return "Invalid MCP response: \(msg)"
        case .serverError(let code, let message):
            return "MCP server error \(code): \(message)"
        case .encodingError(let msg):
            return "MCP encoding error: \(msg)"
        }
    }
}
