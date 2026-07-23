import Foundation

struct LLMRequestAttemptDiagnostics: Codable, Equatable, Identifiable {
    let id: UUID
    var provider: String
    var endpoint: String
    var model: String
    var requestStartedAt: Date
    var responseHeadersAt: Date?
    var firstSSEEventAt: Date?
    var firstParsedOutputAt: Date?
    var responseCompletedAt: Date?
    var taskCompletedAt: Date?
    var domainLookupStartedAt: Date?
    var domainLookupCompletedAt: Date?
    var connectionStartedAt: Date?
    var secureConnectionStartedAt: Date?
    var secureConnectionCompletedAt: Date?
    var connectionCompletedAt: Date?
    var requestUploadStartedAt: Date?
    var requestUploadCompletedAt: Date?
    var firstResponseByteAt: Date?
    var networkResponseCompletedAt: Date?
    var statusCode: Int?
    var networkProtocolName: String?
    var reusedConnection: Bool?
    var requestBodyBytes: Int64?
    var responseBodyBytes: Int64?
    var sseEventCount: Int = 0
    var jsonParseCount: Int = 0
    var sseParsingMilliseconds: Int = 0
    var jsonParsingMilliseconds: Int = 0

    private func millisecondsBetween(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    var dnsLookupMilliseconds: Int? {
        millisecondsBetween(domainLookupStartedAt, domainLookupCompletedAt)
    }

    var tcpConnectionMilliseconds: Int? {
        guard let start = connectionStartedAt else { return nil }
        return millisecondsBetween(start, secureConnectionStartedAt ?? connectionCompletedAt)
    }

    var tlsHandshakeMilliseconds: Int? {
        millisecondsBetween(secureConnectionStartedAt, secureConnectionCompletedAt)
    }

    var connectionMilliseconds: Int? {
        millisecondsBetween(connectionStartedAt, connectionCompletedAt)
    }

    var requestUploadMilliseconds: Int? {
        millisecondsBetween(requestUploadStartedAt, requestUploadCompletedAt)
    }

    /// Time after the request body is sent until the first response byte arrives.
    /// This is the closest client-side approximation of provider processing time.
    var serverWaitMilliseconds: Int? {
        millisecondsBetween(requestUploadCompletedAt, firstResponseByteAt)
    }

    var timeToResponseHeadersMilliseconds: Int? {
        millisecondsBetween(requestStartedAt, responseHeadersAt ?? firstResponseByteAt)
    }

    var responseDownloadMilliseconds: Int? {
        millisecondsBetween(firstResponseByteAt, networkResponseCompletedAt ?? responseCompletedAt)
    }

    var totalRequestMilliseconds: Int? {
        millisecondsBetween(requestStartedAt, taskCompletedAt ?? responseCompletedAt)
    }

    var firstSSEEventDelayMilliseconds: Int? {
        millisecondsBetween(firstResponseByteAt ?? responseHeadersAt, firstSSEEventAt)
    }

    var firstParsedOutputDelayMilliseconds: Int? {
        millisecondsBetween(firstSSEEventAt, firstParsedOutputAt)
    }

    var unaccountedClientMilliseconds: Int? {
        guard let total = totalRequestMilliseconds else { return nil }
        let accounted = (dnsLookupMilliseconds ?? 0)
            + (connectionMilliseconds ?? 0)
            + (requestUploadMilliseconds ?? 0)
            + (serverWaitMilliseconds ?? 0)
            + (responseDownloadMilliseconds ?? 0)
        return max(0, total - accounted)
    }
}

final class LLMRequestDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [UUID: LLMRequestAttemptDiagnostics] = [:]
    private var orderedIDs: [UUID] = []
    private var sseParsingDurations: [UUID: TimeInterval] = [:]
    private var jsonParsingDurations: [UUID: TimeInterval] = [:]

    func beginAttempt(provider: String, endpoint: URL, model: String) -> UUID {
        let id = UUID()
        let attempt = LLMRequestAttemptDiagnostics(
            id: id,
            provider: provider,
            endpoint: endpoint.absoluteString,
            model: model,
            requestStartedAt: Date()
        )
        lock.withLock {
            attempts[id] = attempt
            orderedIDs.append(id)
        }
        return id
    }

    func markResponseHeaders(id: UUID, statusCode: Int) {
        update(id) {
            $0.responseHeadersAt = $0.responseHeadersAt ?? Date()
            $0.statusCode = statusCode
        }
    }

    func recordSSEParsing(id: UUID, duration: TimeInterval, yieldedEvent: Bool) {
        lock.withLock {
            guard var attempt = attempts[id] else { return }
            let total = (sseParsingDurations[id] ?? 0) + duration
            sseParsingDurations[id] = total
            attempt.sseParsingMilliseconds = Self.milliseconds(total)
            if yieldedEvent {
                attempt.sseEventCount += 1
                attempt.firstSSEEventAt = attempt.firstSSEEventAt ?? Date()
            }
            attempts[id] = attempt
        }
    }

    func recordJSONParsing(id: UUID, duration: TimeInterval, producedOutput: Bool) {
        lock.withLock {
            guard var attempt = attempts[id] else { return }
            let total = (jsonParsingDurations[id] ?? 0) + duration
            jsonParsingDurations[id] = total
            attempt.jsonParsingMilliseconds = Self.milliseconds(total)
            attempt.jsonParseCount += 1
            if producedOutput {
                attempt.firstParsedOutputAt = attempt.firstParsedOutputAt ?? Date()
            }
            attempts[id] = attempt
        }
    }

    func markResponseCompleted(id: UUID) {
        update(id) { $0.responseCompletedAt = $0.responseCompletedAt ?? Date() }
    }

    func apply(metrics: URLSessionTaskMetrics, task: URLSessionTask, id: UUID) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        update(id) {
            $0.domainLookupStartedAt = transaction.domainLookupStartDate
            $0.domainLookupCompletedAt = transaction.domainLookupEndDate
            $0.connectionStartedAt = transaction.connectStartDate
            $0.secureConnectionStartedAt = transaction.secureConnectionStartDate
            $0.secureConnectionCompletedAt = transaction.secureConnectionEndDate
            $0.connectionCompletedAt = transaction.connectEndDate
            $0.requestUploadStartedAt = transaction.requestStartDate
            $0.requestUploadCompletedAt = transaction.requestEndDate
            $0.firstResponseByteAt = transaction.responseStartDate
            $0.networkResponseCompletedAt = transaction.responseEndDate
            $0.networkProtocolName = transaction.networkProtocolName
            $0.reusedConnection = transaction.isReusedConnection
            $0.requestBodyBytes = transaction.countOfRequestBodyBytesSent
            $0.responseBodyBytes = transaction.countOfResponseBodyBytesReceived
            $0.statusCode = ($0.statusCode ?? (task.response as? HTTPURLResponse)?.statusCode)
        }
    }

    func markTaskCompleted(id: UUID) {
        update(id) { $0.taskCompletedAt = $0.taskCompletedAt ?? Date() }
    }

    func snapshot() -> [LLMRequestAttemptDiagnostics] {
        lock.withLock { orderedIDs.compactMap { attempts[$0] } }
    }

    func settledSnapshot(timeout: TimeInterval = 0.25) async -> [LLMRequestAttemptDiagnostics] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = snapshot()
            if current.allSatisfy({ $0.taskCompletedAt != nil }) {
                return current
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot()
    }

    private func update(_ id: UUID, mutation: (inout LLMRequestAttemptDiagnostics) -> Void) {
        lock.withLock {
            guard var attempt = attempts[id] else { return }
            mutation(&attempt)
            attempts[id] = attempt
        }
    }

    private static func milliseconds(_ duration: TimeInterval) -> Int {
        max(0, Int((duration * 1000).rounded()))
    }
}

final class LLMURLSessionMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let diagnosticsHeader = "X-Typeflux-Diagnostics-ID"

    private let lock = NSLock()
    private var recorders: [UUID: LLMRequestDiagnosticsRecorder] = [:]

    func register(id: UUID, recorder: LLMRequestDiagnosticsRecorder) {
        lock.withLock { recorders[id] = recorder }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let id = diagnosticsID(for: task), let recorder = recorder(for: id) else { return }
        recorder.apply(metrics: metrics, task: task, id: id)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError _: Error?
    ) {
        guard let id = diagnosticsID(for: task) else { return }
        let recorder = lock.withLock { recorders.removeValue(forKey: id) }
        recorder?.markTaskCompleted(id: id)
    }

    private func diagnosticsID(for task: URLSessionTask) -> UUID? {
        let value = task.currentRequest?.value(forHTTPHeaderField: Self.diagnosticsHeader)
            ?? task.originalRequest?.value(forHTTPHeaderField: Self.diagnosticsHeader)
        return value.flatMap(UUID.init(uuidString:))
    }

    private func recorder(for id: UUID) -> LLMRequestDiagnosticsRecorder? {
        lock.withLock { recorders[id] }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
