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
}

protocol RealtimeDiagnosticsProviding: AnyObject {
    func diagnosticsSnapshot() async -> RealtimeTranscriptionDiagnosticsSnapshot
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

    private func update(_ body: (inout RealtimeTranscriptionDiagnosticsSnapshot) -> Void) {
        lock.lock()
        body(&snapshot)
        lock.unlock()
    }
}

actor ObservedRealtimeTranscriptionSession: RealtimeTranscriptionSession,
    RealtimeDiagnosticsProviding {
    private let upstream: any RealtimeTranscriptionSession
    private let diagnostics: RealtimeTranscriptionDiagnostics

    init(upstream: any RealtimeTranscriptionSession, diagnostics: RealtimeTranscriptionDiagnostics) {
        self.upstream = upstream
        self.diagnostics = diagnostics
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
            diagnostics.markFinishCompleted()
            return result
        } catch {
            await captureConnectionReadyIfPossible()
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
}
