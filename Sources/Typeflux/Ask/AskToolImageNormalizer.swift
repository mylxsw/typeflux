import Foundation
import TypefluxMediaProtocol

/// Bounds input ownership before starting background work. The worker retains its
/// own slot/files until confirmed collection even when this caller is cancelled.
final class AskToolImageNormalizer: @unchecked Sendable {
    private static let shared = AskToolImageNormalizer()
    private let lock = NSLock()
    private var active = 0
    private let worker: MediaWorker
    init(worker: MediaWorker = .previews) { self.worker = worker }

    static func valid(_ url: String) -> Bool {
        let prefix = "data:image/jpeg;base64,"
        guard url.utf8.count <= MediaLimits.imageBytes, url.hasPrefix(prefix),
              let bytes = Data(base64Encoded: String(url.dropFirst(prefix.count))) else { return false }
        return MediaJPEG.isNormalized(bytes)
    }

    static func image(_ data: Data, type: MediaImageType) async throws -> String {
        try await shared.normalize(data, type: type)
    }

    func normalize(_ data: Data, type: MediaImageType) async throws -> String {
        try await normalize(data, type: type, authorization: worker.authorization())
    }

    /// A continuation can retain its enclosing operation's original native authority.
    func normalize(_ data: Data, type: MediaImageType, authorization: MediaWorker.Authorization) async throws -> String {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { throw MediaFailure.tooLarge }
        try Task.checkCancellation()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        guard lock.withLock({ guard active < 2 else { return false }; active += 1; return true })
        else { throw MediaFailure.unavailable }
        defer { lock.withLock { active -= 1 } }
        let cancellation = AskSearchCancellation()
        let cancelled: @Sendable () -> Bool = { [worker] in cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) { [worker] in
                if cancelled() { throw CancellationError() }
                return try worker.perform(.normalizeImage, input: .data(data), normalization: type,
                                   authorization: authorization, isCancelled: cancelled) { response, _ in
                    guard let image = response.items.first?.image else { throw MediaFailure.invalidProtocol }
                    return image
                }
            }.value
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            return result
        } onCancel: { cancellation.cancel() }
    }
}
