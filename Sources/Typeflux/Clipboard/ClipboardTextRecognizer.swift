import Foundation
import TypefluxMediaProtocol

/// File-only OCR. Shared screenshot/redaction recognizers retain their exact geometry contract.
struct ClipboardTextRecognizer: Sendable {
    private static let admission = AskToolPixelBudget(limit: 2)
    var worker: MediaWorker = .clipboardOCR
    func recognize(_ url: URL) async throws -> String? {
        try Task.checkCancellation()
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            let text = try await Task.detached(priority: .userInitiated) {
                if cancellation.isCancelled { throw CancellationError() }
                let revision = try ClipboardImageRevision(url)
                let result = try worker.decode(.clipboardOCR, input: .file(url), isCancelled: { cancellation.isCancelled })
                guard revision.matches(url), let ocr = result.ocr else { throw MediaFailure.unreadable }
                return ocr.text
            }.value
            try Task.checkCancellation()
            return text
        } onCancel: { cancellation.cancel() }
    }
}
