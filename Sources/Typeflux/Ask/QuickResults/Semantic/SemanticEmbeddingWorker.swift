import CryptoKit
import Foundation

enum SemanticModel {
    static let bytes: Int64 = 309_855_456
    static let sha256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    static let url =
        URL(
            string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf"
        )!
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Typeflux/SemanticSearch", isDirectory: true)
    static var modelURL: URL {
        directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
    }

    static var helperURL: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // swift build developers can build the optional helper without installing an app.
        var folder = AskFileReader.executableURL.deletingLastPathComponent()
        for _ in 0 ..< 7 {
            if folder.lastPathComponent == ".build" {
                return folder.appendingPathComponent("semantic/TypefluxSemanticHelper")
            }
            folder.deleteLastPathComponent()
        }
        return bundled
    }

    static func verify(_ url: URL, bytes: Int64 = Self.bytes, sha256: String = Self.sha256,
                       cancelled: () -> Bool = { false }) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), total: Int64 = 0
        while true {
            if cancelled() {
                throw CancellationError()
            }
            try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
            // A long synchronous indexing job does not drain the thread's outer Cocoa pool.
            // Keep FileHandle's bridged temporary buffers bounded independently of model size.
            let count = try autoreleasepool {
                guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return 0 }
                total += Int64(data.count)
                guard total <= bytes else { throw SemanticFileStore.Failure.invalidVector }
                hash.update(data: data)
                return data.count
            }
            if count == 0 {
                break
            }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == bytes, digest == sha256 else { throw SemanticFileStore.Failure.invalidVector }
    }

    static func install(_ source: URL, to target: URL, bytes: Int64 = Self.bytes, sha256: String = Self.sha256,
                        cancelled: () -> Bool) throws {
        try verify(source, bytes: bytes, sha256: sha256, cancelled: cancelled)
        if cancelled() {
            throw CancellationError()
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let staging = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        // Validate the bytes actually copied, not only the earlier source read.
        // External filesystem mutation is still not an immutable transaction.
        try self.verify(staging, bytes: bytes, sha256: sha256, cancelled: cancelled)
        if cancelled() {
            throw CancellationError()
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(
                target,
                withItemAt: staging,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

enum SemanticEmbeddingRefusal: Error { case rejected }

protocol SemanticEmbedding: AnyObject {
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]]
    func release()
}

extension SemanticEmbedding { func release() {} }

protocol SemanticQueryEmbedding: AnyObject, Sendable {
    func query(_ text: String, lifecycle: AskSearchCancellation) async throws -> [Float]
    func stop()
    func prepare(lifecycle: AskSearchCancellation) async throws
}

extension SemanticQueryEmbedding {
    func prepare(lifecycle _: AskSearchCancellation) async throws {}
}

protocol SemanticModelHandling: Sendable {
    func verify(_ url: URL, cancelled: @Sendable () -> Bool) throws
    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws
    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)
}

struct SemanticModelFiles: SemanticModelHandling {
    func verify(_ url: URL, cancelled: @Sendable () -> Bool) throws {
        try SemanticModel.verify(url, cancelled: cancelled)
    }

    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        try SemanticModel.install(url, to: target, cancelled: cancelled)
    }

    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        try await SemanticModelDownload(progress: progress).fetch()
    }
}

/// One serial owner per helper; query and indexing instances never share an inference queue.
final class SemanticEmbeddingWorker: SemanticEmbedding, SemanticQueryEmbedding, SemanticMediaEmbedding,
    @unchecked Sendable {
    private let queue: DispatchQueue
    private let reader: AskFileReader
    private let idleTimeout: TimeInterval
    private let authorization: SemanticEmbeddingOwnership.Authorization
    private let ownership: SemanticEmbeddingOwnership
    private let lifecycle: AskSearchCancellation
    static let maximumPending = 32
    private let requestsLock = NSLock()
    private var pending: [Request] = []
    private var draining = false
    private var shutdown = AskSearchCancellation()
    private var activeEpoch: AskSearchCancellation?
    private var idleGeneration = 0
    private var queryCache: [String: [Float]] = [:]
    private var queryOrder: [String] = []
    private struct Request {
        var text: String
        var lifecycle: AskSearchCancellation
        var cancelled: AskSearchCancellation
        var epoch: AskSearchCancellation
        var continuation: CheckedContinuation<[Float], Error>
        var trace: SemanticSearchTrace
        var requiresReadyHelper: Bool
    }

    init(
        helper: URL,
        model: URL,
        indexing: Bool = false,
        projector: URL? = nil,
        timeout: TimeInterval = 3,
        startupTimeout: TimeInterval = 15,
        idleTimeout: TimeInterval = 60,
        ownership: SemanticEmbeddingOwnership = SemanticEmbeddingOwnership(),
        authorization: SemanticEmbeddingOwnership.Authorization? = nil,
        lifecycle: AskSearchCancellation = AskSearchCancellation(),
        reaper: OwnedProcessReaper = .shared
    ) {
        queue = DispatchQueue(
            label: "typeflux.semantic.\(indexing ? "index" : "query")",
            qos: indexing ? .utility : .userInitiated
        )
        self.idleTimeout = idleTimeout
        self.ownership = ownership; self.lifecycle = lifecycle
        self.authorization = authorization ?? ownership.authorization()
        self.reader = AskFileReader(
            executable: helper,
            arguments: [model.path] + (projector.map { [$0.path] } ?? []) + (indexing ? ["--background"] : []),
            timeout: indexing ? max(45, timeout) : timeout,
            startupTimeout: indexing ? max(90, startupTimeout) : startupTimeout,
            qualityOfService: projector != nil ? .background : (indexing ? .utility : .userInitiated),
            ownership: ownership.native, reaper: reaper
        )
        if indexing {
            SemanticWorkBudget.current?.register(self)
        }
    }

    /// Synchronous indexing adapter. Its caller exclusively owns this instance.
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        try ownership.perform(authorization: authorization, cancelled: { self.lifecycle.isCancelled || cancelled() }) {
            try embed(texts, trace: nil, cancelled: { self.lifecycle.isCancelled || cancelled() })
        }
    }

    private func embed(_ texts: [String], trace: SemanticSearchTrace?, cancelled: () -> Bool) throws -> [[Float]] {
        guard !cancelled() else { throw CancellationError() }
        let response = try SemanticSearchTrace.$current.withValue(trace) {
            try reader.read(.init(operation: .embedding, path: "", texts: texts), isCancelled: cancelled)
        }
        if let timing = response.semanticTiming, let trace {
            if let load = timing.modelLoadMilliseconds {
                trace.measure("model-load", milliseconds: load)
            }
            trace.measure("model-encode", milliseconds: timing.encodingMilliseconds)
        }
        if response.error != nil, response.embeddings == nil { throw SemanticEmbeddingRefusal.rejected }
        guard response.error == nil, let vectors = response.embeddings, vectors.count == texts.count,
              vectors.allSatisfy(SemanticFileStore.valid) else {
            ownership.invalidVector(authorization); throw SemanticFileStore.Failure.invalidVector
        }
        return vectors
    }

    func release() {
        reader.stop()
    }

    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        try ownership.perform(authorization: authorization, cancelled: { self.lifecycle.isCancelled || cancelled() }) {
            let response = try reader.read(.init(operation: .embedding, path: "", media: input),
                                           isCancelled: { self.lifecycle.isCancelled || cancelled() })
            if response.error != nil, response.embeddings == nil {
                if response.error == EINVAL { throw SemanticMediaInputError.unreadable }
                throw SemanticEmbeddingRefusal.rejected
            }
            guard response.error == nil, response.embeddings?.count == 1, let vector = response.embeddings?.first,
                  SemanticFileStore.valid(vector) else {
                ownership.invalidVector(authorization); throw SemanticFileStore.Failure.invalidVector
            }
            return vector
        }
    }

    func prepare(lifecycle: AskSearchCancellation) async throws {
        _ = try await query("warmup", lifecycle: lifecycle, requiresReadyHelper: true)
    }

    func query(_ text: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        try await query(text, lifecycle: lifecycle, requiresReadyHelper: false)
    }

    private func query(_ text: String, lifecycle: AskSearchCancellation,
                       requiresReadyHelper: Bool) async throws -> [Float] {
        let token = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let trace = SemanticSearchTrace.current ?? .init()
                let (discarded, start, rejected): ([Request], Bool, Bool) = requestsLock.withLock {
                    let request = Request(text: text, lifecycle: lifecycle, cancelled: token, epoch: shutdown,
                                          continuation: continuation, trace: trace,
                                          requiresReadyHelper: requiresReadyHelper)
                    let discarded = pending
                        .filter { $0.text != text || $0.cancelled.isCancelled || $0.lifecycle.isCancelled }
                    pending.removeAll { $0.text != text || $0.cancelled.isCancelled || $0.lifecycle.isCancelled }
                    guard pending.count < Self.maximumPending, !self.lifecycle.isCancelled, ownership.permits(authorization) else {
                        return (discarded, false, true)
                    }
                    pending.append(request)
                    let start = !draining
                    draining = true
                    return (discarded, start, false)
                }
                trace.mark("helper-enqueued")
                for old in discarded {
                    old.continuation.resume(throwing: CancellationError())
                }
                if rejected { continuation.resume(throwing: AskFileReadError.unavailable) }
                if start {
                    queue.async { [self] in drain() }
                }
            }
        } onCancel: { token.cancel() }
    }

    /// At most one inference and one pending query. Same-query waiters reuse its vector.
    /// An obsolete inference finishes without killing a healthy model; scope/voice cancellation still aborts it.
    private func drain() {
        while true {
            let requests: [Request] = requestsLock.withLock {
                let requests = pending
                pending.removeAll()
                if requests.isEmpty {
                    draining = false
                }
                return requests
            }
            guard !requests.isEmpty else { return }
            idleGeneration += 1
            let active = requests.filter {
                !$0.cancelled.isCancelled && !$0.lifecycle.isCancelled && !$0.epoch.isCancelled
            }
            let result: Result<[Float], Error>
            if let first = active.first {
                result = Result {
                    try ownership.perform(authorization: authorization, cancelled: { self.lifecycle.isCancelled || first.epoch.isCancelled || first.lifecycle.isCancelled }) {
                        try queryVector(first, requiresReadyHelper: active.contains { $0.requiresReadyHelper })
                    }
                }
            } else {
                result = .failure(CancellationError())
            }
            for request in requests {
                if request.cancelled.isCancelled || request.lifecycle.isCancelled || request.epoch.isCancelled || lifecycle.isCancelled || !ownership.permits(authorization) {
                    request.continuation.resume(throwing: CancellationError())
                } else {
                    request.continuation.resume(with: result)
                }
            }
            let ticket = idleGeneration
            queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self] in
                guard let self, idleGeneration == ticket else { return }
                reader.stop()
            }
        }
    }

    private func queryVector(_ first: Request, requiresReadyHelper: Bool) throws -> [Float] {
        let stop = first.epoch
        if activeEpoch !== stop {
            reader.stop(); queryCache.removeAll(); queryOrder.removeAll(); activeEpoch = stop
        }
        first.trace.mark("helper-queue-end")
        // Cached query vectors survive idle release; preparation must actually reload the helper.
        if let vector = queryCache[first.text], !requiresReadyHelper || reader.isRunning {
            first.trace.mark("cache-hit"); return vector
        }
        // A missing reply may follow model loading or inference. Do not replay
        // that operation; a later explicit request may open a retired helper.
        guard !stop.isCancelled, !first.lifecycle.isCancelled, !lifecycle.isCancelled else { throw CancellationError() }
        let vector = try embed(["task: search result | query: " + first.text], trace: first.trace,
                               cancelled: { stop.isCancelled || first.lifecycle.isCancelled || self.lifecycle.isCancelled })[0]
        guard !stop.isCancelled, !first.lifecycle.isCancelled, !lifecycle.isCancelled else { throw CancellationError() }
        queryCache[first.text] = vector
        queryOrder.removeAll { $0 == first.text }; queryOrder.append(first.text)
        if queryOrder.count > 16 {
            queryCache.removeValue(forKey: queryOrder.removeFirst())
        }
        return vector
    }

    func stop() {
        let abandoned = requestsLock.withLock {
            shutdown.cancel(); shutdown = AskSearchCancellation()
            let abandoned = pending; pending.removeAll()
            return abandoned
        }
        for request in abandoned {
            request.continuation.resume(throwing: CancellationError())
        }
        queue.async { [self] in
            guard activeEpoch?.isCancelled == true else { return }
            idleGeneration += 1; reader.stop(); queryCache.removeAll(); queryOrder.removeAll(); activeEpoch = nil
        }
    }
}
