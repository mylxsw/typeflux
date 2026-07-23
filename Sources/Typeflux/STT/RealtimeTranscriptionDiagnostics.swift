import AVFoundation
import Foundation

struct RealtimeTranscriptionDiagnosticsSnapshot: Sendable, Equatable {
    var sessionStartedAt: Date?
    var connectionReadyAt: Date?
    var firstAudioSubmittedAt: Date?
    var firstResultReceivedAt: Date?
    var finalResultReceivedAt: Date?
    var finishStartedAt: Date?
    var finishCompletedAt: Date?
    var transport: NetworkTransportDiagnosticsSnapshot?
}

struct NetworkTransportDiagnosticsSnapshot: Codable, Sendable, Equatable {
    var endpoint: String?
    var credentialLookupStartedAt: Date?
    var credentialLookupCompletedAt: Date?
    var routeLookupStartedAt: Date?
    var routeLookupCompletedAt: Date?
    var serverSelectionStartedAt: Date?
    var serverSelectionCompletedAt: Date?
    var webSocketTaskResumedAt: Date?
    var startMessageSentAt: Date?
    var domainLookupStartedAt: Date?
    var domainLookupCompletedAt: Date?
    var connectionStartedAt: Date?
    var secureConnectionStartedAt: Date?
    var secureConnectionCompletedAt: Date?
    var connectionCompletedAt: Date?
    var requestStartedAt: Date?
    var requestCompletedAt: Date?
    var firstResponseByteAt: Date?
    var responseCompletedAt: Date?
    var networkProtocolName: String?
    var reusedConnection: Bool?
    var messageParsingMilliseconds: Int = 0
    var parsedMessageCount: Int = 0

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

    var requestToUpgradeResponseMilliseconds: Int? {
        millisecondsBetween(requestCompletedAt, firstResponseByteAt)
    }
}

final class NetworkTransportDiagnosticsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetworkTransportDiagnosticsSnapshot
    private var metricsCollected = false
    private var messageParsingDuration: TimeInterval = 0

    init(endpoint: URL?) {
        value = NetworkTransportDiagnosticsSnapshot(endpoint: endpoint?.absoluteString)
    }

    func updateEndpoint(_ endpoint: URL?) {
        update { $0.endpoint = endpoint?.absoluteString }
    }

    func markCredentialLookupStarted() {
        update { $0.credentialLookupStartedAt = $0.credentialLookupStartedAt ?? Date() }
    }

    func markCredentialLookupCompleted() {
        update { $0.credentialLookupCompletedAt = $0.credentialLookupCompletedAt ?? Date() }
    }

    func markRouteLookupStarted() {
        update { $0.routeLookupStartedAt = $0.routeLookupStartedAt ?? Date() }
    }

    func markRouteLookupCompleted() {
        update { $0.routeLookupCompletedAt = $0.routeLookupCompletedAt ?? Date() }
    }

    func markServerSelectionStarted() {
        update { $0.serverSelectionStartedAt = $0.serverSelectionStartedAt ?? Date() }
    }

    func markServerSelectionCompleted() {
        update { $0.serverSelectionCompletedAt = $0.serverSelectionCompletedAt ?? Date() }
    }

    func markWebSocketTaskResumed() {
        update { $0.webSocketTaskResumedAt = $0.webSocketTaskResumedAt ?? Date() }
    }

    func markStartMessageSent() {
        update { $0.startMessageSentAt = $0.startMessageSentAt ?? Date() }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        lock.lock()
        value.domainLookupStartedAt = transaction.domainLookupStartDate
        value.domainLookupCompletedAt = transaction.domainLookupEndDate
        value.connectionStartedAt = transaction.connectStartDate
        value.secureConnectionStartedAt = transaction.secureConnectionStartDate
        value.secureConnectionCompletedAt = transaction.secureConnectionEndDate
        value.connectionCompletedAt = transaction.connectEndDate
        value.requestStartedAt = transaction.requestStartDate
        value.requestCompletedAt = transaction.requestEndDate
        value.firstResponseByteAt = transaction.responseStartDate
        value.responseCompletedAt = transaction.responseEndDate
        value.networkProtocolName = transaction.networkProtocolName
        value.reusedConnection = transaction.isReusedConnection
        metricsCollected = true
        lock.unlock()
    }

    func snapshot() -> NetworkTransportDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func recordMessageParsing(duration: TimeInterval) {
        lock.lock()
        messageParsingDuration += duration
        value.messageParsingMilliseconds = max(0, Int((messageParsingDuration * 1000).rounded()))
        value.parsedMessageCount += 1
        lock.unlock()
    }

    private func update(_ mutation: (inout NetworkTransportDiagnosticsSnapshot) -> Void) {
        lock.lock()
        mutation(&value)
        lock.unlock()
    }

    func settledSnapshot(timeout: TimeInterval = 0.25) async -> NetworkTransportDiagnosticsSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (isReady, current) = currentState()
            if isReady { return current }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot()
    }

    private func currentState() -> (Bool, NetworkTransportDiagnosticsSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        return (metricsCollected, value)
    }
}

protocol RealtimeDiagnosticsProviding: AnyObject {
    func diagnosticsSnapshot() async -> RealtimeTranscriptionDiagnosticsSnapshot
}

protocol RealtimeTransportDiagnosticsProviding: AnyObject {
    func transportDiagnosticsSnapshot() async -> NetworkTransportDiagnosticsSnapshot?
}

protocol RealtimeTranscriptionConnectionAwaiting: AnyObject {
    func waitUntilConnectionReady() async throws
}

/// Adds provider-independent timing around every realtime transcription session.
/// The same recorder is also captured by the result callback so timings cover
/// both outbound audio and inbound recognition events.
final class RealtimeTranscriptionDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = RealtimeTranscriptionDiagnosticsSnapshot()

    func markSessionStarted() {
        update { $0.sessionStartedAt = $0.sessionStartedAt ?? Date() }
    }

    func markConnectionReady() {
        update { $0.connectionReadyAt = $0.connectionReadyAt ?? Date() }
    }

    func markFirstAudioSubmitted() {
        update { $0.firstAudioSubmittedAt = $0.firstAudioSubmittedAt ?? Date() }
    }

    func markResult(isFinal: Bool) {
        update {
            $0.firstResultReceivedAt = $0.firstResultReceivedAt ?? Date()
            if isFinal { $0.finalResultReceivedAt = Date() }
        }
    }

    func markFinishStarted() {
        update { $0.finishStartedAt = $0.finishStartedAt ?? Date() }
    }

    func markFinishCompleted() {
        update { $0.finishCompletedAt = Date() }
    }

    func currentSnapshot() -> RealtimeTranscriptionDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func mergeTransport(_ transport: NetworkTransportDiagnosticsSnapshot?) {
        guard let transport else { return }
        update { $0.transport = transport }
    }

    private func update(_ body: (inout RealtimeTranscriptionDiagnosticsSnapshot) -> Void) {
        lock.lock()
        body(&snapshot)
        lock.unlock()
    }
}

actor ObservedRealtimeTranscriptionSession: RealtimeTranscriptionSession,
    RealtimeDiagnosticsProviding,
    RealtimeASROptimizeProviding {
    private let upstream: any RealtimeTranscriptionSession
    private let diagnostics: RealtimeTranscriptionDiagnostics
    nonisolated let asrOptimize: Bool?

    init(
        upstream: any RealtimeTranscriptionSession,
        diagnostics: RealtimeTranscriptionDiagnostics,
        asrOptimize: Bool?
    ) {
        self.upstream = upstream
        self.diagnostics = diagnostics
        self.asrOptimize = asrOptimize
    }

    func start() async {
        diagnostics.markSessionStarted()
        await upstream.start()
        if let awaiting = upstream as? any RealtimeTranscriptionConnectionAwaiting {
            Task { [diagnostics] in
                do {
                    try await awaiting.waitUntilConnectionReady()
                    diagnostics.markConnectionReady()
                } catch {
                    // The session failure is surfaced by finish(); missing ready time
                    // distinguishes connection failures in the persisted diagnostics.
                }
            }
        } else {
            diagnostics.markConnectionReady()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        await upstream.append(buffer)
        diagnostics.markFirstAudioSubmitted()
    }

    func finish() async throws -> String {
        diagnostics.markFinishStarted()
        do {
            let result = try await upstream.finish()
            await captureConnectionReadyIfPossible()
            await captureTransportDiagnosticsIfPossible()
            diagnostics.markFinishCompleted()
            return result
        } catch {
            await captureConnectionReadyIfPossible()
            await captureTransportDiagnosticsIfPossible()
            diagnostics.markFinishCompleted()
            throw error
        }
    }

    func cancel() async {
        await upstream.cancel()
    }

    func diagnosticsSnapshot() -> RealtimeTranscriptionDiagnosticsSnapshot {
        diagnostics.currentSnapshot()
    }

    private func captureConnectionReadyIfPossible() async {
        guard diagnostics.currentSnapshot().connectionReadyAt == nil,
              let awaiting = upstream as? any RealtimeTranscriptionConnectionAwaiting
        else { return }
        if await (try? awaiting.waitUntilConnectionReady()) != nil {
            diagnostics.markConnectionReady()
        }
    }

    private func captureTransportDiagnosticsIfPossible() async {
        guard let provider = upstream as? any RealtimeTransportDiagnosticsProviding else { return }
        diagnostics.mergeTransport(await provider.transportDiagnosticsSnapshot())
    }
}
