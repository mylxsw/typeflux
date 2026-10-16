import CoreGraphics
import Foundation

enum SemanticMediaModel {
    static let bytes: Int64 = 554_821_024
    static let sha256 = "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"
    static let name = "mmproj-embeddinggemma-2-Q8_0.gguf"
    static let url = URL(string:
        "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/\(name)")!
}

struct SemanticMediaModelFiles: SemanticModelHandling {
    func verify(_ url: URL, cancelled: @Sendable () -> Bool) throws {
        try SemanticModel.verify(url, bytes: SemanticMediaModel.bytes, sha256: SemanticMediaModel.sha256,
                                 cancelled: cancelled)
    }

    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        try SemanticModel.install(url, to: target, bytes: SemanticMediaModel.bytes, sha256: SemanticMediaModel.sha256,
                                  cancelled: cancelled)
    }

    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        try await SemanticModelDownload(url: SemanticMediaModel.url, progress: progress).fetch()
    }
}

enum SemanticMediaIdle {
    static func isIdle() -> Bool {
        let events: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown,
                                     .rightMouseDown, .scrollWheel]
        let idle = events.map { event in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: event)
        }.min() ?? 0
        return idle >= 15
    }
}

/// Lazy media runtime: document bursts have priority; media loads its projector at an idle checkpoint.
final class SemanticMediaWorker: SemanticMediaEmbedding {
    private let helper: URL
    private let model: URL
    private let projector: URL
    private let models: any SemanticModelHandling
    private let makeEncoder: Factory
    private let embeddingOwners: SemanticEmbeddingOwners
    private let authorization: SemanticEmbeddingOwnership.Authorization
    private let progress: @Sendable (Double?) -> Void
    private var encoder: (any SemanticMediaEmbedding)?

    typealias Factory = @Sendable (URL, URL, URL) -> any SemanticMediaEmbedding

    init(
        helper: URL,
        model: URL,
        projector: URL,
        models: any SemanticModelHandling = SemanticMediaModelFiles(),
        makeEncoder: Factory? = nil,
        progress: @escaping @Sendable (Double?) -> Void = { _ in },
        embeddingOwners: SemanticEmbeddingOwners = SemanticEmbeddingOwners(),
        authorization: SemanticEmbeddingOwnership.Authorization? = nil
    ) {
        self.helper = helper; self.model = model; self.projector = projector
        self.models = models; self.progress = progress; self.embeddingOwners = embeddingOwners
        let authorization = authorization ?? embeddingOwners.media.authorization()
        self.authorization = authorization
        self.makeEncoder = makeEncoder ?? { helper, model, projector in
            SemanticEmbeddingWorker(helper: helper, model: model, indexing: true, projector: projector,
                                    timeout: 90, startupTimeout: 180, ownership: embeddingOwners.media, authorization: authorization)
        }
    }

    func embed(_ input: SemanticMediaInput, cancelled originalCancelled: () -> Bool) throws -> [Float] {
        guard embeddingOwners.media.permits(authorization) else { throw AskFileReadError.unavailable }
        @Sendable func cancelled() -> Bool { originalCancelled() || !embeddingOwners.media.permits(authorization) }
        // Check at this boundary even when a custom model/encoder ignores its
        // cancellation callback. An entered operation still owns its cleanup.
        if cancelled() { throw CancellationError() }
        if encoder == nil {
            do { try models.verify(projector, cancelled: { cancelled() }) } catch {
                if cancelled() {
                    throw CancellationError()
                }
                try download(cancelled: cancelled)
            }
            if cancelled() {
                throw CancellationError()
            }
            encoder = makeEncoder(helper, model, projector)
        }
        if cancelled() { throw CancellationError() }
        let result = try encoder!.embed(input, cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        return result
    }

    func release() {
        encoder?.release(); encoder = nil
    }

    private final class Transfer: @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var result: Result<(URL, URLResponse), Error>?
    }

    private func download(cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        let mutation = try embeddingOwners.mutation(.projector)
        defer { mutation.finish() }
        let transfer = Transfer(), models = models, progress = progress
        progress(0)
        defer { progress(nil) }
        // The synchronous progress sink may revoke the original scope.
        if cancelled() { throw CancellationError() }
        let task = Task.detached {
            let result: Result<(URL, URLResponse), Error>
            do {
                result = try await .success(models.fetch {
                    progress(min(1, Double($0) / Double(SemanticMediaModel.bytes)))
                })
            } catch { result = .failure(error) }
            transfer.lock.withLock { transfer.result = result }; transfer.done.signal()
        }
        // Join the transfer even on cancellation; no detached download outlives its indexing job.
        while transfer.done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() {
                task.cancel()
            }
        }
        let (temporary, response) = try transfer.lock.withLock { try transfer.result!.get() }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if cancelled() {
            throw CancellationError()
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try models.install(temporary, to: projector, cancelled: { cancelled() })
    }
}
