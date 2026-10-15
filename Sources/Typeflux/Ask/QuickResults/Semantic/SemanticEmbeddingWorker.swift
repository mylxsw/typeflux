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
        for _ in 0..<7 {
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
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            if cancelled() {
                throw CancellationError()
            }
            total += Int64(data.count)
            guard total <= bytes else { throw SemanticFileStore.Failure.invalidVector }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == bytes, digest == sha256 else { throw SemanticFileStore.Failure.invalidVector }
    }

    static func install(_ source: URL, to target: URL, bytes: Int64 = Self.bytes, sha256: String = Self.sha256,
                        cancelled: () -> Bool) throws {
        try self.verify(source, bytes: bytes, sha256: sha256, cancelled: cancelled)
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
        if cancelled() {
            throw CancellationError()
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(
                target,
                withItemAt: staging
            )
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

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
    }

    init(
        helper: URL,
        model: URL,
        indexing: Bool = false,
        projector: URL? = nil,
        timeout: TimeInterval = 3,
        startupTimeout: TimeInterval = 15
    ) {
        self.queue = DispatchQueue(
            label: "typeflux.semantic.\(indexing ? "index" : "query")",
            qos: indexing ? .utility : .userInitiated
        )
        self.reader = AskFileReader(
            executable: helper,
            arguments: [model.path] + (projector.map { [$0.path] } ?? []),
            timeout: indexing ? max(45, timeout) : timeout,
            startupTimeout: indexing ? max(90, startupTimeout) : startupTimeout,
            qualityOfService: projector != nil ? .background : (indexing ? .utility : .userInitiated)
        )
    }

    /// Synchronous indexing adapter. Its caller exclusively owns this instance.
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        try embed(texts, trace: nil, cancelled: cancelled)
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
        guard response.error == nil, let vectors = response.embeddings, vectors.count == texts.count,
              vectors.allSatisfy(SemanticFileStore.valid) else { throw SemanticFileStore.Failure.invalidVector }
        return vectors
    }

    func release() { reader.stop() }

    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        guard !cancelled() else { throw CancellationError() }
        let response = try reader.read(.init(operation: .embedding, path: "", media: input), isCancelled: cancelled)
        if response.error == EINVAL { throw SemanticMediaInputError.unreadable }
        guard response.error == nil, let vector = response.embeddings?.first,
              SemanticFileStore.valid(vector) else { throw SemanticFileStore.Failure.invalidVector }
        return vector
    }

    func prepare(lifecycle: AskSearchCancellation) async throws {
        _ = try await query("warmup", lifecycle: lifecycle)
    }

    func query(_ text: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        let token = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let trace = SemanticSearchTrace.current ?? .init()
                let (discarded, start): ([Request], Bool) = requestsLock.withLock {
                    let request = Request(text: text, lifecycle: lifecycle, cancelled: token, epoch: shutdown,
                                          continuation: continuation, trace: trace)
                    let discarded = pending
                        .filter { $0.text != text || $0.cancelled.isCancelled || $0.lifecycle.isCancelled }
                    pending.removeAll { $0.text != text || $0.cancelled.isCancelled || $0.lifecycle.isCancelled }
                    pending.append(request)
                    let start = !draining
                    draining = true
                    return (discarded, start)
                }
                trace.mark("helper-enqueued")
                for old in discarded {
                    old.continuation.resume(throwing: CancellationError())
                }
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
                if requests.isEmpty { draining = false }
                return requests
            }
            guard !requests.isEmpty else { return }
            idleGeneration += 1
            let active = requests.filter {
                !$0.cancelled.isCancelled && !$0.lifecycle.isCancelled && !$0.epoch.isCancelled
            }
            let result: Result<[Float], Error>
            if let first = active.first {
                result = Result { try queryVector(first) }
            } else {
                result = .failure(CancellationError())
            }
            for request in requests {
                if request.cancelled.isCancelled || request.lifecycle.isCancelled || request.epoch.isCancelled {
                    request.continuation.resume(throwing: CancellationError())
                } else {
                    request.continuation.resume(with: result)
                }
            }
            let ticket = idleGeneration
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, idleGeneration == ticket else { return }
                reader.stop()
            }
        }
    }

    private func queryVector(_ first: Request) throws -> [Float] {
        let stop = first.epoch
        if activeEpoch !== stop {
            reader.stop(); queryCache.removeAll(); queryOrder.removeAll(); activeEpoch = stop
        }
        first.trace.mark("helper-queue-end")
        if let vector = queryCache[first.text] {
            first.trace.mark("cache-hit"); return vector
        }
        var vector: [Float] = []
        for attempt in 0 ..< 2 {
            guard !stop.isCancelled, !first.lifecycle.isCancelled else { throw CancellationError() }
            do {
                vector = try embed(["task: search result | query: " + first.text], trace: first.trace,
                                   cancelled: { stop.isCancelled || first.lifecycle.isCancelled })[0]
                break
            } catch let error as AskFileReadError {
                guard attempt == 0, !stop.isCancelled, !first.lifecycle.isCancelled,
                      error != .cancelled else { throw error }
                reader.stop()
                first.trace.mark("helper-restart")
            }
        }
        guard !stop.isCancelled, !first.lifecycle.isCancelled else { throw CancellationError() }
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
        for request in abandoned { request.continuation.resume(throwing: CancellationError()) }
        queue.async { [self] in
            guard activeEpoch?.isCancelled == true else { return }
            idleGeneration += 1; reader.stop(); queryCache.removeAll(); queryOrder.removeAll(); activeEpoch = nil
        }
    }
}
