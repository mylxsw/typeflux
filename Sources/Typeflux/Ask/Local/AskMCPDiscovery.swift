import Foundation

/// The directory searches only the MCP definitions the host admitted for this run.
enum AskMCPDiscovery {
    static let name = "find_external_tools"
    static let pageSize = 4

    static func external(_ tool: AskToolDefinition) -> Bool { tool.name.hasPrefix("mcp_") }

    static func server(_ tool: AskToolDefinition) -> String {
        if let server = tool.mcpServer { return server }
        let prefix = "MCP server: "
        guard tool.description.hasPrefix(prefix) else { return "" }
        return String(tool.description.dropFirst(prefix.count).components(separatedBy: ". ")[0])
    }

    static func directory(_ catalog: [AskToolDefinition]) -> AskToolDefinition {
        let servers = Set(catalog.map(server).filter { !$0.isEmpty }).sorted().joined(separator: ", ")
        return .init(name: name,
            description: "Find tools from connected services: " + String(servers.prefix(1200))
                + ". Search with short capability keywords in the tool's language (often English, even for other user languages). Omit query to browse. Matching tools become callable on the next step.",
            parameters: JSONValue(data: Data(#"{"type":"object","properties":{"query":{"type":"string"},"server":{"type":"string","description":"Optional exact service name"},"offset":{"type":"integer","minimum":0}},"additionalProperties":false}"#.utf8)))
    }

    struct Page {
        var names: [String]
        var text: String
    }

    static func search(_ arguments: String, catalog: [AskToolDefinition]) -> Page {
        struct Query: Decodable { var query: String?; var server: String?; var offset: Int? }
        guard let query = try? JSONDecoder().decode(Query.self, from: Data(arguments.utf8)) else {
            return Page(names: [], text: "Use query, server or an integer offset. Use {} to browse.")
        }
        let terms = Set((query.query ?? "").prefix(256).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let service = query.server?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = catalog.filter { service.isEmpty || server($0).caseInsensitiveCompare(service) == .orderedSame }
        var ranked: [(name: String, score: Int)] = []
        for tool in candidates {
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            var score = 0
            for term in terms {
                if name.contains(term) { score += 4 }
                else if description.contains(term) { score += 1 }
            }
            if terms.isEmpty || score > 0 { ranked.append((tool.name, score)) }
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.name < rhs.name : lhs.score > rhs.score
        }
        let offset = min(ranked.count, max(0, query.offset ?? 0))
        let names = ranked.dropFirst(offset).prefix(pageSize).map { $0.name }
        if names.isEmpty {
            return Page(names: [], text: "No matches on this page. Try English keywords, omit server, or browse with {}.")
        }
        let next = offset + names.count
        return Page(names: names, text: "Call a matching tool to retrieve the requested data. Available tools: " + names.joined(separator: ", ")
            + (next < ranked.count ? ". More matches at offset \(next)." : "."))
    }
}
