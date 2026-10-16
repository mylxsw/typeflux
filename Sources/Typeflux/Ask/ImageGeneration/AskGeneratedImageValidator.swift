import Foundation
import TypefluxMediaProtocol

/// Admission precedes detached work; the worker owns input copies through reaping.
final class AskGeneratedImageValidator: @unchecked Sendable {
    static let shared = AskGeneratedImageValidator()
    private let lock = NSLock()
    private var active = 0
    private let worker: MediaWorker
    init(worker: MediaWorker = .previews) { self.worker = worker }

    func validate(_ data: Data) async throws -> AskGeneratedImageData {
        guard !data.isEmpty, data.count <= AskArtifactStore.maximumFileBytes else { throw AskImageError.tooLarge }
        guard lock.withLock({ guard active < 2 else { return false }; active += 1; return true })
        else { throw MediaFailure.unavailable }
        defer { lock.withLock { active -= 1 } }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let metadata = try await Task.detached(priority: .utility) { [worker] in
                try worker.perform(.validateGeneratedImage, input: .data(data), isCancelled: { cancellation.isCancelled }) { response, _ in
                    guard let metadata = response.generatedImage else { throw MediaFailure.invalidProtocol }
                    return metadata
                }
            }.value
            try Task.checkCancellation()
            return .init(data: data, mediaType: metadata.mediaType, width: metadata.width, height: metadata.height)
        } onCancel: { cancellation.cancel() }
    }
}
