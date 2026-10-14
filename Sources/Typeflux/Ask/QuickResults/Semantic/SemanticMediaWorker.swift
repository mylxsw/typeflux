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

/// Lazy media runtime: documents finish first; only idle media work downloads/loads the additional projector.
final class SemanticMediaWorker: SemanticMediaEmbedding {
    private let helper: URL
    private let model: URL
    private let projector: URL
    private let models: any SemanticModelHandling
    private let makeEncoder: @Sendable (URL, URL, URL) -> any SemanticMediaEmbedding
    private let progress: @Sendable (Double?) -> Void
    private var encoder: (any SemanticMediaEmbedding)?

    typealias Factory = @Sendable (URL, URL, URL) -> any SemanticMediaEmbedding
    static let defaultEncoder: Factory = {
        SemanticEmbeddingWorker(helper: $0, model: $1, indexing: true, projector: $2,
                                timeout: 90, startupTimeout: 180)
    }

    init(
        helper: URL,
        model: URL,
        projector: URL,
        models: any SemanticModelHandling = SemanticMediaModelFiles(),
        makeEncoder: @escaping Factory = SemanticMediaWorker.defaultEncoder,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) {
        self.helper = helper; self.model = model; self.projector = projector
        self.models = models; self.makeEncoder = makeEncoder; self.progress = progress
    }

    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        if encoder == nil {
            do { try models.verify(projector, cancelled: { cancelled() }) } catch {
                if cancelled() { throw CancellationError() }
                try download(cancelled: cancelled)
            }
            if cancelled() { throw CancellationError() }
            encoder = makeEncoder(helper, model, projector)
        }
        return try encoder!.embed(input, cancelled: cancelled)
    }

    private final class Transfer: @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var result: Result<(URL, URLResponse), Error>?
    }

    private func download(cancelled: () -> Bool) throws {
        let transfer = Transfer(), models = models, progress = progress
        progress(0)
        defer { progress(nil) }
        let task = Task.detached {
            let result: Result<(URL, URLResponse), Error>
            do {
                result = .success(try await models.fetch {
                    progress(min(1, Double($0) / Double(SemanticMediaModel.bytes)))
                })
            } catch { result = .failure(error) }
            transfer.lock.withLock { transfer.result = result }; transfer.done.signal()
        }
        // Join the transfer even on cancellation; no detached download outlives its indexing job.
        while transfer.done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() { task.cancel() }
        }
        let (temporary, response) = try transfer.lock.withLock { try transfer.result!.get() }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if cancelled() { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try models.install(temporary, to: projector, cancelled: { cancelled() })
    }
}
