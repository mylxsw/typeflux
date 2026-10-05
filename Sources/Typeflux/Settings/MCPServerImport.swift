import Foundation

/// Reads MCP servers from the JSON other clients use, so a server README snippet can be pasted as is.
///
/// Accepts `{"mcpServers": {...}}` (Claude Desktop, Cursor), `{"servers": {...}}` (VS Code)
/// or the bare name-to-server map. A server with a `url` uses HTTP; one with a `command` runs locally.
enum MCPServerImport {
    struct Result {
        var servers: [MCPServerConfig]
        /// Names of entries that had neither a command nor a URL.
        var skipped: [String]
    }

    enum ImportError: LocalizedError, Equatable {
        case invalidJSON
        case noServers

        var errorDescription: String? {
            switch self {
            case .invalidJSON: L("agent.mcp.import.invalid")
            case .noServers: L("agent.mcp.import.empty")
            }
        }
    }

    /// Parses `text`; imported names that collide with `existingNames` get a numeric suffix.
    static func parse(_ text: String, existingNames: [String] = []) throws -> Result {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ImportError.invalidJSON }
        let map = (root["mcpServers"] as? [String: Any]) ?? (root["servers"] as? [String: Any]) ?? root
        var taken = Set(existingNames.map { $0.lowercased() })
        var servers: [MCPServerConfig] = []
        var skipped: [String] = []
        for name in map.keys.sorted() {
            guard let entry = map[name] as? [String: Any], let transport = transport(from: entry) else {
                skipped.append(name)
                continue
            }
            let unique = uniqueName(name.trimmingCharacters(in: .whitespacesAndNewlines), taken: taken)
            taken.insert(unique.lowercased())
            servers.append(MCPServerConfig(name: unique, transport: transport))
        }
        guard !servers.isEmpty || !skipped.isEmpty else { throw ImportError.noServers }
        return Result(servers: servers, skipped: skipped)
    }

    private static func transport(from entry: [String: Any]) -> MCPTransportConfig? {
        if let url = (entry["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return .http(MCPHTTPTransportConfig(url: url, headers: strings(entry["headers"])))
        }
        guard let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        let args = (entry["args"] as? [Any] ?? []).compactMap(string)
        return .stdio(MCPStdioTransportConfig(command: command, args: args, env: strings(entry["env"])))
    }

    private static func strings(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        return object.compactMapValues(string)
    }

    private static func string(_ value: Any) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let base = name.isEmpty ? L("agent.mcp.untitled") : name
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }
}

/// One editable `KEY=VALUE` line of an MCP server's environment or request headers.
struct MCPKeyValueRow: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }

    /// Values of these keys are secrets and are masked while editing.
    var isSecret: Bool {
        let lower = key.lowercased()
        return ["key", "token", "secret", "password", "authorization", "cookie"].contains { lower.contains($0) }
    }

    /// Splits the `KEY=VALUE` lines the settings model stores; a line without `=` is a key with no value.
    static func rows(from text: String) -> [MCPKeyValueRow] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let separator = trimmed.firstIndex(of: "=") else { return MCPKeyValueRow(key: trimmed) }
            return MCPKeyValueRow(
                key: String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces),
                value: String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// Joins rows back into `KEY=VALUE` lines, dropping rows without a key.
    static func text(from rows: [MCPKeyValueRow]) -> String {
        rows.compactMap { row in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : "\(key)=\(row.value.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")
    }
}
