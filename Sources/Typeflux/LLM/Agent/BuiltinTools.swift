import Foundation

/// 内置工具标识（扩展 BuiltinAgentToolName 之外的工具名称）
enum BuiltinToolName: String, CaseIterable, Sendable {
    case shellCommand = "shell_command"
    case webFetch = "web_fetch"
}

// MARK: - ShellCommandTool

/// 本地 Shell 命令执行工具
struct ShellCommandTool: AgentTool {
    let definition = LLMAgentTool(
        name: BuiltinToolName.shellCommand.rawValue,
        description: "Execute a shell command locally and return the output. Use for system info, file operations, or calculations. Only safe, read-only commands are recommended.",
        inputSchema: LLMJSONSchema(
            name: BuiltinToolName.shellCommand.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("command")]),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to execute"),
                    ]),
                    "timeout": .object([
                        "type": .string("integer"),
                        "description": .string("Timeout in seconds (default: 30, max: 120)"),
                    ]),
                ]),
            ]
        )
    )

    private let runner: CommandRunner

    init(runner: CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    func execute(arguments: String) async throws -> String {
        struct Args: Codable {
            let command: String
            let timeout: Int?
        }

        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            throw AgentError.toolExecutionFailed(name: definition.name, reason: "Invalid arguments: expected JSON with 'command' field")
        }

        let command = args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw AgentError.toolExecutionFailed(name: definition.name, reason: "Command must not be empty")
        }

        let timeoutSeconds = min(max(args.timeout ?? 30, 1), 120)

        do {
            let output = try await runner.run(
                command: "/bin/sh",
                arguments: ["-c", command],
                timeoutSeconds: timeoutSeconds
            )

            let truncatedOutput = truncateOutput(output, maxLength: 8000)
            let result: [String: Any] = [
                "exitCode": 0,
                "output": truncatedOutput,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [])
            return String(data: jsonData, encoding: .utf8) ?? #"{"error":"encoding failed"}"#
        } catch {
            let result: [String: Any] = [
                "exitCode": -1,
                "error": error.localizedDescription,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [])
            return String(data: jsonData, encoding: .utf8) ?? #"{"error":"encoding failed"}"#
        }
    }

    private func truncateOutput(_ output: String, maxLength: Int) -> String {
        guard output.count > maxLength else { return output }
        let truncated = String(output.prefix(maxLength))
        return truncated + "\n... [output truncated at \(maxLength) characters]"
    }
}

// MARK: - WebFetchTool

/// 网络请求工具
struct WebFetchTool: AgentTool {
    let definition = LLMAgentTool(
        name: BuiltinToolName.webFetch.rawValue,
        description: "Fetch content from a URL. Returns the response body as text. Useful for looking up web pages, API endpoints, or online resources.",
        inputSchema: LLMJSONSchema(
            name: BuiltinToolName.webFetch.rawValue,
            schema: [
                "type": .string("object"),
                "required": .array([.string("url")]),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to fetch content from"),
                    ]),
                    "maxLength": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum response length in characters (default: 5000, max: 20000)"),
                    ]),
                ]),
            ]
        )
    )

    private let fetcher: URLFetcher

    init(fetcher: URLFetcher = DefaultURLFetcher()) {
        self.fetcher = fetcher
    }

    func execute(arguments: String) async throws -> String {
        struct Args: Codable {
            let url: String
            let maxLength: Int?
        }

        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            throw AgentError.toolExecutionFailed(name: definition.name, reason: "Invalid arguments: expected JSON with 'url' field")
        }

        guard let url = URL(string: args.url), url.scheme == "https" || url.scheme == "http" else {
            throw AgentError.toolExecutionFailed(name: definition.name, reason: "Invalid URL: must start with http:// or https://")
        }

        let maxLen = min(max(args.maxLength ?? 5000, 100), 20000)

        do {
            let content = try await fetcher.fetch(url: url, timeoutSeconds: 30)
            let truncated = truncateContent(content, maxLength: maxLen)
            let result: [String: Any] = [
                "url": args.url,
                "content": truncated,
                "contentLength": content.count,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [])
            return String(data: jsonData, encoding: .utf8) ?? #"{"error":"encoding failed"}"#
        } catch {
            let result: [String: Any] = [
                "url": args.url,
                "error": error.localizedDescription,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [])
            return String(data: jsonData, encoding: .utf8) ?? #"{"error":"encoding failed"}"#
        }
    }

    private func truncateContent(_ content: String, maxLength: Int) -> String {
        guard content.count > maxLength else { return content }
        return String(content.prefix(maxLength)) + "\n... [content truncated at \(maxLength) characters]"
    }
}

// MARK: - CommandRunner Protocol

/// 命令执行协议（便于测试注入）
protocol CommandRunner: Sendable {
    func run(command: String, arguments: [String], timeoutSeconds: Int) async throws -> String
}

/// 基于 Process 的默认命令执行器
struct ProcessCommandRunner: CommandRunner {
    func run(command: String, arguments: [String], timeoutSeconds: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments

            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            do {
                try process.run()
                process.waitUntilExit()
                timer.cancel()

                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let combined = stderr.isEmpty ? stdout : stderr
                    continuation.resume(returning: combined)
                }
            } catch {
                timer.cancel()
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - URLFetcher Protocol

/// URL 请求协议（便于测试注入）
protocol URLFetcher: Sendable {
    func fetch(url: URL, timeoutSeconds: Int) async throws -> String
}

/// 基于 URLSession 的默认 URL 请求器
struct DefaultURLFetcher: URLFetcher {
    func fetch(url: URL, timeoutSeconds: Int) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Typeflux Agent",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""
    }
}
