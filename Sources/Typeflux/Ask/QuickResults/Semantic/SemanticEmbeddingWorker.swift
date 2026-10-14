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

    static func verify(_ url: URL, cancelled: () -> Bool = { false }) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), total: Int64 = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            if cancelled() {
                throw CancellationError()
            }
            total += Int64(data.count)
            guard total <= self.bytes else { throw SemanticFileStore.Failure.invalidVector }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == self.bytes, digest == self.sha256 else { throw SemanticFileStore.Failure.invalidVector }
    }

    static func install(_ source: URL, to target: URL, cancelled: () -> Bool) throws {
        try self.verify(source, cancelled: cancelled)
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
}

protocol SemanticQueryEmbedding: AnyObject, Sendable {
    func query(_ text: String, lifecycle: AskSearchCancellation) async throws -> [Float]
    func stop()
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
final class SemanticEmbeddingWorker: SemanticEmbedding, SemanticQueryEmbedding, @unchecked Sendable {
    private let queue: DispatchQueue
    private let reader: AskFileReader
    private var idleGeneration = 0

    init(
        helper: URL,
        model: URL,
        indexing: Bool = false,
        timeout: TimeInterval = 45,
        startupTimeout: TimeInterval = 90
    ) {
        self.queue = DispatchQueue(
            label: "typeflux.semantic.\(indexing ? "index" : "query")",
            qos: indexing ? .utility : .userInitiated
        )
        self.reader = AskFileReader(
            executable: helper,
            arguments: [model.path],
            timeout: timeout,
            startupTimeout: startupTimeout
        )
    }

    /// Synchronous indexing adapter. Its caller exclusively owns this instance.
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        guard !cancelled() else { throw CancellationError() }
        let response = try reader.read(.init(operation: .embedding, path: "", texts: texts), isCancelled: cancelled)
        guard response.error == nil, let vectors = response.embeddings, vectors.count == texts.count,
              vectors.allSatisfy(SemanticFileStore.valid) else { throw SemanticFileStore.Failure.invalidVector }
        return vectors
    }

    func query(_ text: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        let token = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async { [self] in
                    do {
                        self.idleGeneration += 1
                        let vector = try embed(
                            ["task: search result | query: " + text],
                            cancelled: { token.isCancelled || lifecycle.isCancelled }
                        )[0]
                        continuation.resume(returning: vector)
                    } catch { continuation.resume(throwing: error) }
                    let ticket = self.idleGeneration
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, idleGeneration == ticket else { return }
                        self.reader.stop()
                    }
                }
            }
        } onCancel: { token.cancel() }
    }

    func stop() {
        self.queue.async { [self] in self.idleGeneration += 1; self.reader.stop() }
    }
}
