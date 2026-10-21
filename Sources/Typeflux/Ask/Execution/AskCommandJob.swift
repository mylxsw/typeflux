import Foundation

/// Model data is never authority. A scope is minted from an admitted host run.
struct AskCommandJobScope: Equatable, Sendable {
    let owner: String
    let conversation: String
    let run: String
    let device: String
    let generation: UUID
}

enum AskCommandJobError: Error, LocalizedError {
    case invalid, unavailable, capacity, conflict, storage
    var errorDescription: String? {
        switch self {
        case .invalid: "Invalid command job arguments."
        case .unavailable: "Command job unavailable."
        case .capacity: "Command job capacity reached; stop a running job before starting another."
        case .conflict: "Command job invocation already has different arguments. Do not retry it."
        case .storage: "Command job storage unavailable. No new command was admitted."
        }
    }
}

struct AskCommandJobRequest: Equatable, Sendable {
    let action: String
    var command: String = ""
    var timeout: Int = 120
    var handle: String = ""
    var stream: ManagedProcess.Stream = .stdout
    var offset = 0
    var limit = 8192

    static let lifetime = """
    Owned by this run only: run completion, stop or replacement, conversation deletion, account change or app shutdown \
    cancels it. Stop is not rollback. Host commands are not a security sandbox; deliberately escaping processes \
    cannot be contained by POSIX groups.
    """

    static func validated(_ args: [String: Any]) throws -> Self {
        guard let action = args["action"] as? String else { throw AskCommandJobError.invalid }
        var request = Self(action: action)
        let keys: Set<String>
        switch action {
        case "start":
            keys = ["action", "command", "timeout_seconds"]
            guard let command = args["command"] as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !command.contains("\0"), command.utf8.count <= AskHostCommand.maximumCommandBytes else {
                throw AskCommandJobError.invalid
            }
            request.command = command
            request.timeout = try integer(args, "timeout_seconds", fallback: 120, range: 1 ... 600)
        case "status", "stop", "logs":
            keys = action == "logs" ? ["action", "job_id", "stream", "offset", "limit"] : ["action", "job_id"]
            guard let handle = args["job_id"] as? String, UUID(uuidString: handle) != nil,
                  handle == handle.lowercased() else { throw AskCommandJobError.unavailable }
            request.handle = handle
            if action == "logs" {
                guard let stream = (args["stream"] as? String).flatMap(ManagedProcess.Stream.init) else {
                    throw AskCommandJobError.invalid
                }
                request.stream = stream
                request.offset = try integer(args, "offset", fallback: 0, range: 0 ... Int.max)
                request.limit = try integer(args, "limit", fallback: 8192, range: 1 ... 16384)
            }
        default: throw AskCommandJobError.invalid
        }
        guard Set(args.keys).isSubset(of: keys) else { throw AskCommandJobError.invalid }
        return request
    }

    private static func integer(_ args: [String: Any], _ key: String, fallback: Int,
                                range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return fallback }
        // JSONDecoder rejects booleans, fractional values, strings, null and overflow.
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
              let value = try? JSONDecoder().decode(Int.self, from: data), range.contains(value) else {
            throw AskCommandJobError.invalid
        }
        return value
    }

    static var definition: AskToolDefinition {
        definition(allowStart: true)
    }

    static func definition(allowStart: Bool) -> AskToolDefinition {
        let schema: [String: Any] = [
            "type": "object", "required": ["action"], "additionalProperties": false,
            "properties": [
                "action": [
                    "type": "string",
                    "enum": allowStart ? ["start", "status", "logs", "stop"] : ["status", "logs", "stop"]
                ],
                "command": ["type": "string", "minLength": 1, "maxLength": 1200],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 600],
                "job_id": ["type": "string"],
                "stream": ["type": "string", "enum": ["stdout", "stderr"]],
                "offset": ["type": "integer", "minimum": 0],
                "limit": ["type": "integer", "minimum": 1, "maximum": 16384]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys) else {
            preconditionFailure("Invalid command job schema")
        }
        return .init(name: "command_job", description: """
        Run a noninteractive host shell command while doing other work in the SAME run. start requires command,
        optional timeout_seconds 1...600 (default 120), bounded by the run deadline. Same fresh exact-command
        approval and code-execution setting as run_command. No stdin, services or automatic retry.
        start returns admission only, never command success. Inspect status and logs; only exited with code 0
        proves command success. status/stop require job_id only. logs requires job_id and stream stdout|stderr,
        optional byte offset (default 0), limit 1...16384 (default 8192). Retains only a 64 KiB prefix per stream,
        drains excess and reports omitted bytes. Byte slices use lossy UTF-8 decoding; next_offset advances by
        source bytes, including invalid/split sequences. End of retained output does not mean process exit.
        stop is idempotent and reports stopping until bounded cleanup completes. Never rerun for complete logs.
        \(lifetime)
        """, parameters: JSONValue(data: data))
    }
}

/// The drain callback only appends fixed chunks under this lock. No per-chunk tasks,
/// dispatches, filesystem writes, strings or references back into the host store.
final class AskCommandJobBuffer: @unchecked Sendable {
    struct Stream: Codable, Sendable {
        var prefix = Data()
        var omitted: UInt64 = 0
        mutating func append(_ data: Data) {
            let count = min(data.count, 65536 - prefix.count)
            prefix.append(data.prefix(count))
            omitted = omitted.addingReportingOverflow(UInt64(data.count - count)).overflow
                ? UInt64.max : omitted + UInt64(data.count - count)
        }
    }

    struct Snapshot: Sendable {
        var stdout: Stream
        var stderr: Stream
        var started: Bool
    }

    private let lock = NSLock()
    private var stdout: Stream
    private var stderr: Stream
    private var started = false
    private var accepting = true

    init(stdout: Stream = .init(), stderr: Stream = .init()) {
        self.stdout = stdout; self.stderr = stderr
    }

    func markStarted() {
        lock.withLock {
            if accepting {
                started = true
            }
        }
    }

    func append(_ stream: ManagedProcess.Stream, _ data: Data) {
        lock.withLock {
            guard accepting else { return }
            if stream == .stdout {
                stdout.append(data)
            } else {
                stderr.append(data)
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { .init(stdout: stdout, stderr: stderr, started: started) }
    }

    func close() {
        lock.withLock { accepting = false }
    }
}
