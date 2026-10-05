@testable import Typeflux
import XCTest

final class MCPServerImportTests: XCTestCase {
    func testImportsClaudeDesktopConfiguration() throws {
        let json = """
        {"mcpServers": {
          "notion": {"command": "npx", "args": ["-y", "@notionhq/notion-mcp-server", 3], "env": {"NOTION_TOKEN": "t", "PORT": 8080}},
          "linear": {"url": "https://mcp.linear.app/mcp", "headers": {"Authorization": "Bearer x"}},
          "broken": {"args": ["x"]},
          "text": "not an object"
        }}
        """
        let result = try MCPServerImport.parse(json, existingNames: ["Linear"])
        XCTAssertEqual(result.servers.map(\.name), ["linear 2", "notion"])
        XCTAssertEqual(result.skipped, ["broken", "text"])
        XCTAssertTrue(result.servers.allSatisfy { $0.enabled && !$0.autoConnect })
        guard case let .http(http) = result.servers[0].transport else { return XCTFail("Expected HTTP") }
        XCTAssertEqual(http.url, "https://mcp.linear.app/mcp")
        XCTAssertEqual(http.headers, ["Authorization": "Bearer x"])
        guard case let .stdio(stdio) = result.servers[1].transport else { return XCTFail("Expected stdio") }
        XCTAssertEqual(stdio.command, "npx")
        XCTAssertEqual(stdio.args, ["-y", "@notionhq/notion-mcp-server", "3"])
        XCTAssertEqual(stdio.env, ["NOTION_TOKEN": "t", "PORT": "8080"])
    }

    func testImportsVSCodeAndBareMaps() throws {
        let vscode = try MCPServerImport.parse(#"{"servers": {"a": {"type": "http", "url": " https://a.example/mcp "}}}"#)
        XCTAssertEqual(vscode.servers.map(\.name), ["a"])
        guard case let .http(http) = vscode.servers[0].transport else { return XCTFail("Expected HTTP") }
        XCTAssertEqual(http.url, "https://a.example/mcp")
        let bare = try MCPServerImport.parse(#"{"local": {"command": "/usr/bin/tool"}}"#)
        XCTAssertEqual(bare.servers.map(\.name), ["local"])
    }

    func testRejectsInvalidOrEmptyJSON() {
        XCTAssertThrowsError(try MCPServerImport.parse("{")) {
            XCTAssertEqual($0 as? MCPServerImport.ImportError, .invalidJSON)
        }
        XCTAssertThrowsError(try MCPServerImport.parse("[1, 2]")) {
            XCTAssertEqual($0 as? MCPServerImport.ImportError, .invalidJSON)
        }
        XCTAssertThrowsError(try MCPServerImport.parse(#"{"mcpServers": {}}"#)) {
            XCTAssertEqual($0 as? MCPServerImport.ImportError, .noServers)
        }
        XCTAssertEqual(MCPServerImport.ImportError.invalidJSON.errorDescription, L("agent.mcp.import.invalid"))
        XCTAssertEqual(MCPServerImport.ImportError.noServers.errorDescription, L("agent.mcp.import.empty"))
    }

    func testUniqueNames() {
        XCTAssertEqual(MCPServerImport.uniqueName("a", taken: []), "a")
        XCTAssertEqual(MCPServerImport.uniqueName("A", taken: ["a", "a 2"]), "A 3")
        XCTAssertEqual(MCPServerImport.uniqueName("", taken: []), L("agent.mcp.untitled"))
    }

    func testKeyValueRowsRoundTrip() {
        let rows = MCPKeyValueRow.rows(from: " API_KEY = sk-1 \n\nURL=https://x?a=b\nFLAG\n")
        XCTAssertEqual(rows.map(\.key), ["API_KEY", "URL", "FLAG"])
        XCTAssertEqual(rows.map(\.value), ["sk-1", "https://x?a=b", ""])
        XCTAssertEqual(MCPKeyValueRow.text(from: rows + [MCPKeyValueRow(key: "  ", value: "dropped")]),
                       "API_KEY=sk-1\nURL=https://x?a=b\nFLAG=")
        XCTAssertTrue(MCPKeyValueRow(key: "NOTION_TOKEN").isSecret)
        XCTAssertTrue(MCPKeyValueRow(key: "Authorization").isSecret)
        XCTAssertFalse(MCPKeyValueRow(key: "NODE_ENV").isSecret)
    }

    func testServerStatusPresentation() {
        let tool = MCPConnectionTestState.MCPDiscoveredTool(id: "s", name: "search", description: "")
        let cases: [(Bool, MCPConnectionTestState?, MCPServerStatusPresentation.State)] = [
            (false, .success(tools: [tool]), .disabled),
            (true, nil, .untested),
            (true, .idle, .untested),
            (true, .testing, .testing),
            (true, .success(tools: [tool]), .connected),
            (true, .failure(message: "x"), .failed)
        ]
        for (enabled, result, expected) in cases {
            let status = MCPServerStatusPresentation(enabled: enabled, result: result)
            XCTAssertEqual(status.state, expected)
            XCTAssertFalse(status.label.isEmpty)
            _ = status.color
        }
        XCTAssertTrue(MCPServerStatusPresentation(enabled: true, result: .testing).isTesting)
        XCTAssertEqual(MCPServerStatusPresentation(enabled: true, result: .success(tools: [tool])).label,
                       L("agent.mcp.status.connected", 1))
    }
}
