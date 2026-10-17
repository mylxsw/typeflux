import Darwin
import Foundation

/// A user-approved command on the host Mac. This is deliberately separate from
/// the isolated analysis sandbox: it runs with the user's normal file access.
struct AskHostCommand: Sendable {
    static let maximumCommandBytes = 1200
    static let maximumTimeout = 120
    static let defaultTimeout = 60

    static var definition: AskToolDefinition {
        let schema: [String: Any] = [
            "type": "object", "required": ["command"], "additionalProperties": false,
            "properties": [
                "command": ["type": "string", "minLength": 1, "maxLength": maximumCommandBytes],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": maximumTimeout]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)
        return .init(name: "run_command", description: """
        Run one shell command on the user's Mac with their normal account access. Use only when the task requires a command. \
        Show the exact command for a separate user approval before every run, even in YOLO mode. Do not claim that a \
        referenced script was inspected unless you read it. The command starts in the user's home folder, has no \
        interactive terminal, and has a maximum runtime of 120 seconds. Check the exit status and output afterward.
        """, parameters: JSONValue(data: data))
    }

    static func validated(_ args: [String: Any]) throws -> (command: String, timeout: Int) {
        guard Set(args.keys).isSubset(of: ["command", "timeout_seconds"]),
              args["timeout_seconds"] == nil || args["timeout_seconds"] is Int else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        guard let command = args["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= maximumCommandBytes, !command.contains("\0") else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        let timeout = args["timeout_seconds"] as? Int ?? defaultTimeout
        guard (1 ... maximumTimeout).contains(timeout) else { throw AskLocalError.message(L("ask.tool.invalid")) }
        return (command, timeout)
    }

    func run(command: String, timeout: Int) async throws -> AskLocalToolOutput {
        let home = NSHomeDirectory()
        let directory = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        let environment = ["HOME": home, "USER": NSUserName(), "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        let result = try await ManagedProcess().run(.init(
            executable: "/bin/zsh", arguments: ["-f", "-c", command], environment: environment,
            directoryDescriptor: directory, timeout: TimeInterval(timeout), outputLimit: 30_000,
            stopOnOutputLimit: true, preserveWhitespace: true, immediateCleanupOnExit: true
        ))
        if result.termination == .cancelled { throw CancellationError() }
        var lines = ["Exit code: \(result.exitCode)"]
        if result.termination == .timedOut { lines[0] = "Timed out after \(timeout) seconds; the command may have made changes." }
        if result.termination == .outputLimit { lines.append("Output limit reached; the command was stopped.") }
        if !result.stdout.isEmpty { lines += ["--- stdout ---", result.stdout] }
        if !result.stderr.isEmpty { lines += ["--- stderr ---", result.stderr] }
        if result.outputTruncated { lines.append("[output truncated]") }
        return .init(content: lines.joined(separator: "\n"),
                     isError: result.termination != .exited(0) || result.outputTruncated)
    }
}
