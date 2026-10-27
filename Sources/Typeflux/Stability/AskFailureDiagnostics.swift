import Foundation
import os
import SQLite3

/// Persistent, content-free failures survive a presentation process restart.
/// Never persist error descriptions, account IDs, prompts, tokens or SQL text.
final class AskFailureDiagnostics: @unchecked Sendable {
    static let shared = AskFailureDiagnostics()
    static let maximumFileBytes = 256 * 1024
    static let maximumFiles = 8
    static let maximumEvents = 100

    enum Operation: String, Codable, Sendable {
        case recoveryRead, recoveryReadRecovered, recoveryReadExhausted, draftSave
        case cacheCall, cacheModule, cacheAuthorization
        case sqliteOpen, sqlitePrepare, sqliteRead, sqliteWrite
        case rpcRead, rpcWrite, rpcProtocol, rpcQueue
    }

    enum Reason: String, Codable, Sendable {
        case inactiveChannel, generationMismatch, ownerMismatch
        case invalidVersion, malformedReply, malformedRequest, queueLimit, requestLimit
        case peerClosed, frameDeadline, socketError
    }

    struct Event: Codable, Sendable, Equatable {
        let date: Date
        let uptime: TimeInterval
        let pid: Int32
        let role: String
        let operation: Operation
        let kind: String
        let domain: String
        let code: Int
        let underlyingDomain: String?
        let underlyingCode: Int?
        let reason: Reason?
        let method: String?
        let decodingPath: String?
        let sqliteReason: String?
        let frameBytes: Int?
        let transferredBytes: Int?
    }

    private let queue = DispatchQueue(label: "typeflux.ask-failures", qos: .utility)
    private let lock = NSLock()
    private let directoryOverride: URL?
    private var pending = 0
    private var file: URL?
    private var bytes = 0
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "AskFailures")

    init(directory: URL? = nil) { directoryOverride = directory }

    static var directory: URL {
        TypefluxDataDirectories.cache.appendingPathComponent("ask-failures", isDirectory: true)
    }

    func record(_ operation: Operation, error: any Error, reason: Reason? = nil, method: String? = nil,
                frameBytes: Int? = nil, transferredBytes: Int? = nil) {
        // Unit fixtures must not pollute the running application's diagnostics.
        guard directoryOverride != nil || FeatureProcess.enabled else { return }
        guard lock.withLock({ if pending >= 128 { return false }; pending += 1; return true }) else { return }
        let value = error as NSError
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        let event = Event(date: Date(), uptime: ProcessInfo.processInfo.systemUptime,
            pid: ProcessInfo.processInfo.processIdentifier,
            role: FeatureProcess.role.rawValue, operation: operation,
            kind: operation == .recoveryReadRecovered ? "recovered" : Self.kind(error),
            domain: value.domain, code: value.code, underlyingDomain: underlying?.domain,
            underlyingCode: underlying?.code, reason: reason, method: Self.safeMethod(method),
            decodingPath: Self.decodingPath(error),
            sqliteReason: Self.sqliteReason(underlying?.domain == "SQLite" ? underlying : value),
            frameBytes: frameBytes, transferredBytes: transferredBytes)
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            do { try append(event) } catch {
                file = nil; logger.error("Could not persist Ask failure diagnostic")
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private static func kind(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? FeatureRPC.Failure { return "rpc." + error.rawValue }
        if let error = error as? ModuleFailure { return "module." + String(describing: error) }
        if let error = error as? AskRecoveryError {
            switch error {
            case .storage: return "recovery.storage"
            case .binding: return "recovery.binding"
            case .unknown: return "recovery.unknown"
            }
        }
        if case .unauthorized? = error as? AuthError { return "authorization" }
        if error is DecodingError { return "decoding" }
        if error is URLError { return "network" }
        return "operation"
    }

    private static func sqliteReason(_ error: NSError?) -> String? {
        guard let error, error.domain == "SQLite", let code = Int32(exactly: error.code),
              let reason = sqlite3_errstr(code) else { return nil }
        return String(cString: reason)
    }

    private static func safeMethod(_ method: String?) -> String? {
        guard let method else { return nil }
        let names = ["execution", "executions", "claimExecution", "saveRejectedToolReceipt", "saveReceipt",
            "recordExecution", "save", "load", "list", "delete", "saveDraft", "draft", "savedChatDrafts",
            "associateTool", "claimTool", "saveToolResult", "toolResult"]
        return names.enumerated().contains { "cache.\($0.element).\($0.offset)" == method } ? method : "other"
    }

    private static func decodingPath(_ error: any Error) -> String? {
        guard let error = error as? DecodingError else { return nil }
        let path: [any CodingKey]
        switch error {
        case let .keyNotFound(key, context): path = context.codingPath + [key]
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            path = context.codingPath
        @unknown default: return nil
        }
        // Dictionary keys can contain user data. Export only known schema keys.
        let fields: Set<String> = ["payload", "generation", "owner", "identity", "runId", "conversationId", "deviceId",
            "callId", "stepId", "kind", "events", "receipt", "audit", "harness", "outcome", "version", "id", "data",
            "text", "content", "messages", "run", "revision", "updatedAt", "createdAt", "approvedAt", "toolVersion",
            "toolName", "argumentsHash", "deliveryConfirmed", "includeScreenshot", "attachments", "usage"]
        return (["$"] + path.prefix(16).map { key in
            key.intValue != nil ? "[]" : fields.contains(key.stringValue) ? key.stringValue : "*"
        }).joined(separator: ".")
    }

    private func append(_ event: Event) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event); data.append(10)
        let directory = directoryOverride ?? Self.directory
        if file == nil || bytes + data.count > Self.maximumFileBytes
            || !FileManager.default.fileExists(atPath: file!.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("failures-") && $0.pathExtension == "jsonl" }
                .sorted { Self.modification($0) > Self.modification($1) }
            for (index, file) in files.enumerated()
                where index >= Self.maximumFiles - 1 || Date().timeIntervalSince(Self.modification(file)) > 7 * 86400 {
                try? FileManager.default.removeItem(at: file)
            }
            let target = directory.appendingPathComponent("failures-\(UUID().uuidString).jsonl")
            guard FileManager.default.createFile(atPath: target.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            file = target; bytes = 0
        }
        guard let file else { return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
        bytes += data.count
        let message = String(data: data, encoding: .utf8) ?? ""
        if event.operation == .recoveryReadRecovered {
            logger.notice("\(message, privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }

    static func read(directory override: URL? = nil, interval: DateInterval? = nil) throws -> [Event] {
        guard override != nil || FeatureProcess.enabled else { return [] }
        let directory = override ?? Self.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("failures-") && $0.pathExtension == "jsonl" }
            .sorted { modification($0) > modification($1) }.prefix(maximumFiles)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var events: [Event] = []
        for file in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            let data: Data
            do {
                data = try handle.read(upToCount: maximumFileBytes) ?? Data(); try handle.close()
            } catch { try? handle.close(); throw error }
            for line in data.split(separator: 10) {
                guard let event = try? decoder.decode(Event.self, from: Data(line)),
                      interval.map({ $0.contains(event.date) }) ?? true else { continue }
                events.append(event)
            }
        }
        return Array(events.sorted {
            $0.date == $1.date ? $0.uptime > $1.uptime : $0.date > $1.date
        }.prefix(maximumEvents))
    }

    private static func modification(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
