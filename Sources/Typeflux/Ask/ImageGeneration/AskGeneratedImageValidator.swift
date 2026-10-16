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
        try await validate(data, authorization: worker.authorization())
    }

    /// Retaining a stamp never upgrades old received bytes after native recovery.
    func validate(_ data: Data, authorization: MediaWorker.Authorization) async throws -> AskGeneratedImageData {
        guard !data.isEmpty, data.count <= AskArtifactStore.maximumFileBytes else { throw AskImageError.tooLarge }
        try Task.checkCancellation()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        guard lock.withLock({ guard active < 2 else { return false }; active += 1; return true })
        else { throw MediaFailure.unavailable }
        defer { lock.withLock { active -= 1 } }
        let cancellation = AskSearchCancellation()
        let cancelled: @Sendable () -> Bool = { [worker] in cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let metadata = try await Task.detached(priority: .utility) { [worker] in
                if cancelled() { throw CancellationError() }
                return try worker.perform(.validateGeneratedImage, input: .data(data),
                    authorization: authorization, isCancelled: cancelled) { response, _ in
                    guard let metadata = response.generatedImage else { throw MediaFailure.invalidProtocol }
                    return metadata
                }
            }.value
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            return .init(data: data, mediaType: metadata.mediaType, width: metadata.width, height: metadata.height)
        } onCancel: { cancellation.cancel() }
    }
}
