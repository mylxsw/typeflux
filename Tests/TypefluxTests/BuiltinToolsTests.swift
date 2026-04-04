import XCTest
@testable import Typeflux

// MARK: - Mock CommandRunner

final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    var mockOutput: String = ""
    var shouldThrow: Bool = false
    var lastCommand: String?
    var lastArguments: [String]?
    var lastTimeout: Int?

    func run(command: String, arguments: [String], timeoutSeconds: Int) async throws -> String {
        lastCommand = command
        lastArguments = arguments
        lastTimeout = timeoutSeconds
        if shouldThrow {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command failed"])
        }
        return mockOutput
    }
}

// MARK: - Mock URLFetcher

final class MockURLFetcher: URLFetcher, @unchecked Sendable {
    var mockContent: String = ""
    var shouldThrow: Bool = false
    var lastURL: URL?
    var lastTimeout: Int?

    func fetch(url: URL, timeoutSeconds: Int) async throws -> String {
        lastURL = url
        lastTimeout = timeoutSeconds
        if shouldThrow {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fetch failed"])
        }
        return mockContent
    }
}

// MARK: - ShellCommandTool Tests

final class ShellCommandToolTests: XCTestCase {

    // MARK: Definition

    func testShellCommandToolDefinitionName() {
        let tool = ShellCommandTool()
        XCTAssertEqual(tool.definition.name, "shell_command")
    }

    func testShellCommandToolDefinitionDescription() {
        let tool = ShellCommandTool()
        XCTAssertFalse(tool.definition.description.isEmpty)
        XCTAssertTrue(tool.definition.description.contains("shell"))
    }

    func testShellCommandToolNotTerminationTool() {
        let tool = ShellCommandTool()
        XCTAssertFalse(tool is any TerminationTool)
    }

    // MARK: Execute

    func testExecuteValidCommand() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = "Hello, World!"
        let tool = ShellCommandTool(runner: runner)

        let result = try await tool.execute(arguments: #"{"command": "echo Hello"}"#)
        XCTAssertTrue(result.contains("Hello, World!"))
        XCTAssertTrue(result.contains("\"exitCode\""))
        XCTAssertEqual(runner.lastCommand, "/bin/sh")
        XCTAssertEqual(runner.lastArguments, ["-c", "echo Hello"])
    }

    func testExecuteWithDefaultTimeout() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = "output"
        let tool = ShellCommandTool(runner: runner)

        _ = try await tool.execute(arguments: #"{"command": "test"}"#)
        XCTAssertEqual(runner.lastTimeout, 30)
    }

    func testExecuteWithCustomTimeout() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = "output"
        let tool = ShellCommandTool(runner: runner)

        _ = try await tool.execute(arguments: #"{"command": "test", "timeout": 60}"#)
        XCTAssertEqual(runner.lastTimeout, 60)
    }

    func testExecuteWithTimeoutClamping() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = ""
        let tool = ShellCommandTool(runner: runner)

        // Max 120
        _ = try await tool.execute(arguments: #"{"command": "test", "timeout": 999}"#)
        XCTAssertEqual(runner.lastTimeout, 120)

        // Min 1
        _ = try await tool.execute(arguments: #"{"command": "test", "timeout": 0}"#)
        XCTAssertEqual(runner.lastTimeout, 1)
    }

    func testExecuteInvalidArguments() async {
        let tool = ShellCommandTool()
        do {
            _ = try await tool.execute(arguments: "not json")
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testExecuteEmptyCommand() async {
        let runner = MockCommandRunner()
        let tool = ShellCommandTool(runner: runner)
        do {
            _ = try await tool.execute(arguments: #"{"command": "  "}"#)
            XCTFail("Expected error for empty command")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testExecuteCommandFailure() async throws {
        let runner = MockCommandRunner()
        runner.shouldThrow = true
        let tool = ShellCommandTool(runner: runner)

        let result = try await tool.execute(arguments: #"{"command": "failing_command"}"#)
        XCTAssertTrue(result.contains("\"error\""))
        XCTAssertTrue(result.contains("\"exitCode\""))
    }

    func testExecuteOutputTruncation() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = String(repeating: "x", count: 10000)
        let tool = ShellCommandTool(runner: runner)

        let result = try await tool.execute(arguments: #"{"command": "big_output"}"#)
        XCTAssertTrue(result.contains("truncated"))
    }

    func testExecuteShortOutputNotTruncated() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = "short"
        let tool = ShellCommandTool(runner: runner)

        let result = try await tool.execute(arguments: #"{"command": "short_output"}"#)
        XCTAssertFalse(result.contains("truncated"))
    }

    func testResultIsValidJSON() async throws {
        let runner = MockCommandRunner()
        runner.mockOutput = "result with \"quotes\" and \nnewlines"
        let tool = ShellCommandTool(runner: runner)

        let result = try await tool.execute(arguments: #"{"command": "echo test"}"#)
        let data = result.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}

// MARK: - WebFetchTool Tests

final class WebFetchToolTests: XCTestCase {

    // MARK: Definition

    func testWebFetchToolDefinitionName() {
        let tool = WebFetchTool()
        XCTAssertEqual(tool.definition.name, "web_fetch")
    }

    func testWebFetchToolDefinitionDescription() {
        let tool = WebFetchTool()
        XCTAssertFalse(tool.definition.description.isEmpty)
        XCTAssertTrue(tool.definition.description.contains("URL"))
    }

    func testWebFetchToolNotTerminationTool() {
        let tool = WebFetchTool()
        XCTAssertFalse(tool is any TerminationTool)
    }

    // MARK: Execute

    func testExecuteValidURL() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = "Hello from the web"
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com"}"#)
        XCTAssertTrue(result.contains("Hello from the web"))
        XCTAssertTrue(result.contains("\"url\""))
        XCTAssertTrue(result.contains("\"content\""))
        XCTAssertEqual(fetcher.lastURL?.absoluteString, "https://example.com")
    }

    func testExecuteWithHTTPURL() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = "content"
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "http://example.com"}"#)
        XCTAssertTrue(result.contains("content"))
    }

    func testExecuteInvalidURL() async {
        let tool = WebFetchTool()
        do {
            _ = try await tool.execute(arguments: #"{"url": "not-a-url"}"#)
            XCTFail("Expected error for invalid URL")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testExecuteWithFTPScheme() async {
        let tool = WebFetchTool()
        do {
            _ = try await tool.execute(arguments: #"{"url": "ftp://example.com/file"}"#)
            XCTFail("Expected error for FTP URL")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testExecuteInvalidArguments() async {
        let tool = WebFetchTool()
        do {
            _ = try await tool.execute(arguments: "not json")
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }

    func testExecuteWithDefaultMaxLength() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = String(repeating: "a", count: 6000)
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com"}"#)
        XCTAssertTrue(result.contains("truncated"))
    }

    func testExecuteWithCustomMaxLength() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = String(repeating: "a", count: 200)
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com", "maxLength": 150}"#)
        XCTAssertTrue(result.contains("truncated"))
    }

    func testExecuteMaxLengthClamping() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = String(repeating: "a", count: 25000)
        let tool = WebFetchTool(fetcher: fetcher)

        // Max 20000
        let result = try await tool.execute(arguments: #"{"url": "https://example.com", "maxLength": 50000}"#)
        XCTAssertTrue(result.contains("truncated at 20000"))
    }

    func testExecuteShortContentNotTruncated() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = "short"
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com"}"#)
        XCTAssertFalse(result.contains("truncated"))
    }

    func testExecuteFetchFailure() async throws {
        let fetcher = MockURLFetcher()
        fetcher.shouldThrow = true
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com"}"#)
        XCTAssertTrue(result.contains("\"error\""))
    }

    func testResultIsValidJSON() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = "content with \"quotes\""
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com"}"#)
        let data = result.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testResultIncludesContentLength() async throws {
        let fetcher = MockURLFetcher()
        fetcher.mockContent = "hello"
        let tool = WebFetchTool(fetcher: fetcher)

        let result = try await tool.execute(arguments: #"{"url": "https://example.com"}"#)
        XCTAssertTrue(result.contains("\"contentLength\""))
    }
}
