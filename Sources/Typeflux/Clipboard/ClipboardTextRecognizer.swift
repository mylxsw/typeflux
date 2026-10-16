import Foundation
import TypefluxMediaProtocol

/// File-only OCR. Shared screenshot/redaction recognizers retain their exact geometry contract.
struct ClipboardTextRecognizer: Sendable {
    private static let admission = AskToolPixelBudget(limit: 2)
    var worker: MediaWorker = .clipboardOCR
    var readRevision: @Sendable (URL) throws -> ClipboardImageRevision = { try ClipboardImageRevision($0) }
    func recognize(_ url: URL, authorization original: MediaWorker.Authorization? = nil) async throws -> String? {
        try Task.checkCancellation()
        let worker = self.worker, readRevision = self.readRevision
        let authorization = original ?? worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation()
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            let text = try await Task.detached(priority: .userInitiated) {
                guard !cancelled() else { throw CancellationError() }
                let revision = try readRevision(url)
                guard !cancelled() else { throw CancellationError() }
                let result = try worker.perform(.clipboardOCR, input: .file(url), authorization: authorization,
                                                isCancelled: cancelled) { response, _ in response }
                guard revision.matches(url), let ocr = result.ocr else { throw MediaFailure.unreadable }
                guard !cancelled() else { throw CancellationError() }
                return ocr.text
            }.value
            try Task.checkCancellation()
            guard worker.permits(authorization) else { throw MediaFailure.unavailable }
            return text
        } onCancel: { cancellation.cancel() }
    }
}
