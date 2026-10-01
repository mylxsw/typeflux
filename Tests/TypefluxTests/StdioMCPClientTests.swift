@testable import Typeflux
import XCTest

/// Exercises the real process/pipe transport against a small shell MCP server.
final class StdioMCPClientTests: XCTestCase {
    private var directory: URL!
    private var script: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stdio-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fake-mcp")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeClient(env: [String: String] = [:], timeout: Duration = .seconds(10)) -> StdioMCPClient {
        StdioMCPClient(config: MCPStdioConfig(command: script.path, env: env, requestTimeout: timeout))
    }

    func testConnectListsEveryPageAndCallsTools() async throws {
        let client = makeClient()
        try await client.connect()
        let info = await client.serverInfo
        XCTAssertEqual(info?.name, "fake")

        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["first", "second"])

        // The server sends a notification and a same-ID server request before the
        // response; neither may resolve the pending call.
        let result = try await client.callTool(name: "echo", arguments: [:])
        XCTAssertEqual(result.textContent, "ok")
        try await client.ping()
        await client.disconnect()
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testJSONRPCErrorsCarryTheServerMessage() async throws {
        let client = makeClient()
        try await client.connect()
        do {
            _ = try await client.callTool(name: "fail", arguments: [:])
            XCTFail("Expected a server error")
        } catch let MCPClientError.serverError(code, message) {
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "tool exploded")
        }
        await client.disconnect()
    }

    func testStderrOutputDoesNotBlockTheServer() async throws {
        let client = makeClient(env: ["FAKE_MCP_NOISY": "1"])
        try await client.connect()
        let result = try await client.callTool(name: "noisy", arguments: [:])
        XCTAssertEqual(result.textContent, "ok")
        await client.disconnect()
    }

    func testStalledRequestTimesOut() async throws {
        let client = makeClient(timeout: .milliseconds(500))
        try await client.connect()
        do {
            _ = try await client.callTool(name: "hang", arguments: [:])
            XCTFail("Expected a timeout")
        } catch MCPClientError.timedOut {}
        await client.disconnect()
    }

    func testCancellingACallStopsWaiting() async throws {
        let client = makeClient()
        try await client.connect()
        let call = Task { try await client.callTool(name: "hang", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(200))
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        await client.disconnect()
    }

    func testServerExitFailsPendingRequests() async throws {
        let client = makeClient()
        try await client.connect()
        do {
            _ = try await client.callTool(name: "exit", arguments: [:])
            XCTFail("Expected a disconnected error")
        } catch MCPClientError.notConnected {}
        // Later calls fail cleanly instead of writing into a closed pipe.
        do {
            _ = try await client.callTool(name: "echo", arguments: [:])
            XCTFail("Expected a disconnected error")
        } catch MCPClientError.notConnected {}
    }

    func testMissingCommandFailsToLaunch() async throws {
        let client = StdioMCPClient(config: MCPStdioConfig(command: "typeflux-missing-mcp-\(UUID().uuidString)"))
        do {
            try await client.connect()
            XCTFail("Expected a launch failure")
        } catch MCPClientError.launchFailed {}
    }

    func testBareCommandsResolveThroughTheLaunchPath() throws {
        XCTAssertEqual(StdioMCPClient.resolveExecutable("fake-mcp", searchPath: "/nonexistent:" + directory.path)?.path, script.path)
        XCTAssertEqual(StdioMCPClient.resolveExecutable(script.path, searchPath: "")?.path, script.path)
        XCTAssertNil(StdioMCPClient.resolveExecutable("fake-mcp", searchPath: "/nonexistent"))
        XCTAssertNil(StdioMCPClient.resolveExecutable("  ", searchPath: directory.path))
        // A directory with the command's name is not executable.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("tool-dir"), withIntermediateDirectories: true)
        XCTAssertNil(StdioMCPClient.resolveExecutable("tool-dir", searchPath: directory.path))
        XCTAssertEqual(StdioMCPClient.resolveExecutable("sh", searchPath: "/bin")?.path, "/bin/sh")
    }

    func testLaunchEnvironmentAddsCommonDirectoriesWithoutReordering() {
        let environment = StdioMCPClient.launchEnvironment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
            overrides: ["PATH": "/custom/bin:/usr/bin", "TOKEN": "configured"],
            home: "/Users/test"
        )
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(Array(path.prefix(2)), ["/custom/bin", "/usr/bin"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/Users/test/.local/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(environment["TOKEN"], "configured")
        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertTrue(StdioMCPClient.launchEnvironment(base: [:], overrides: [:], home: "/h")["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
    }

    private static let server = #"""
    #!/bin/sh
    # Minimal line-delimited MCP server used by StdioMCPClientTests.
    noise() {
      i=0
      while [ $i -lt 3000 ]; do
        echo "diagnostic line $i ................................................................" >&2
        i=$((i + 1))
      done
    }
    respond() { printf '%s\n' "$1"; }
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
      method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')
      [ -z "$id" ] && continue
      case "$method" in
        initialize)
          respond '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1.0"}}}' ;;
        tools/list)
          if printf '%s' "$line" | grep -q '"cursor":"page2"'; then
            respond '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[{"name":"second","inputSchema":{"type":"object"}}]}}'
          else
            respond '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[{"name":"first","inputSchema":{"type":"object"}}],"nextCursor":"page2"}}'
          fi ;;
        tools/call)
          if printf '%s' "$line" | grep -q '"name":"hang"'; then
            sleep 5
          elif printf '%s' "$line" | grep -q '"name":"exit"'; then
            exit 0
          elif printf '%s' "$line" | grep -q '"name":"fail"'; then
            respond '{"jsonrpc":"2.0","id":"'"$id"'","error":{"code":-32000,"message":"tool exploded"}}'
          else
            [ -n "$FAKE_MCP_NOISY" ] && noise
            respond '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}'
            respond '{"jsonrpc":"2.0","id":"'"$id"'","method":"ping"}'
            respond '{"jsonrpc":"2.0","id":"'"$id"'","result":{"content":[{"type":"text","text":"ok"}],"isError":false}}'
          fi ;;
        *)
          respond '{"jsonrpc":"2.0","id":"'"$id"'","result":{}}' ;;
      esac
    done
    """#
}
