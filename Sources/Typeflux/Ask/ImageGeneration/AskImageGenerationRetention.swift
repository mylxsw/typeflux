import Foundation

/// A private, bounded journal reserved before the paid POST. It is not an artifact
/// grant. Pending records survive decoder failure, cancellation and process restart.
/// No deinit/expiry path deletes originals; conversation deletion is explicit.
final class AskImageGenerationRetention: @unchecked Sendable {
    struct Identity: Codable, Equatable {
        var ownerId: String
        var conversationId: String
        var runId: String
        var callId: String
    }
    static let maximumPending = 8
    static let maximumRecords = 1024
    let id: String
    private let rootURL: URL
    private let identity: Identity
    private let lock = NSLock()
    private var total = 0
    private var downloads = 0

    static func root(for store: AskArtifactStore) -> URL {
        store.storageURL.appendingPathExtension("generation-retention")
    }

    init(rootURL: URL, scope: AskProjectScope, callId: String, metadata: Data) throws {
        guard ![scope.ownerId, scope.conversationId, scope.runId, callId].contains(where: \.isEmpty),
              metadata.count <= 64 * 1024 else { throw AskArtifactError.invalid }
        self.rootURL = rootURL
        identity = .init(ownerId: scope.ownerId, conversationId: scope.conversationId, runId: scope.runId, callId: callId)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(identity)
        guard encoded.count <= 16 * 1024 else { throw AskArtifactError.tooLarge }
        id = AskSecureDirectory.sessionName(String(decoding: encoded, as: UTF8.self))
        let root = try AskSecureDirectory.openRoot(rootURL)
        try root.lock()
        let entries = root.entries(limit: Self.maximumRecords)
        guard entries.count < Self.maximumRecords, !entries.contains(id) else { throw AskArtifactError.unavailable }
        let pending = entries.filter { name in
            guard let directory = try? root.child(name, privateDirectory: true) else { return true }
            let files = directory.entries(limit: 16)
            return !files.contains("published.json") || files.contains("response.json") || files.contains(where: { $0.hasPrefix("download-") })
        }
        guard pending.count < Self.maximumPending else { throw AskArtifactError.tooLarge }
        let directory = try root.child(id, create: true, privateDirectory: true)
        try directory.createFile("identity.json", data: encoded)
        try directory.createFile("request.json", data: metadata)
    }

    func response(_ data: Data) throws {
        guard data.count <= AskImageGenerationService.maximumResponseBytes else { throw AskArtifactError.tooLarge }
        try write("response.json", data: data)
    }

    func downloaded(_ data: Data) throws {
        try lock.withLock {
            guard downloads < 8, data.count <= AskArtifactStore.maximumFileBytes,
                  data.count <= AskArtifactStore.maximumBundleBytes - total else { throw AskArtifactError.tooLarge }
            // Reserve before the write: partial disk writes must not reopen the budget.
            let index = downloads; downloads += 1; total += data.count
            try write("download-\(index)", data: data)
        }
    }

    private func write(_ name: String, data: Data) throws {
        let root = try AskSecureDirectory.openRoot(rootURL, create: false)
        try root.lock()
        let directory = try root.child(id, privateDirectory: true)
        guard try directory.readFile("identity.json", limit: 16 * 1024).decodedIdentity() == identity
        else { throw AskArtifactError.denied }
        try directory.createFile(name, data: data)
    }

    /// Only after every original is durably published elsewhere may redundant
    /// response/download bytes be removed. The identity remains to refuse replay.
    func published(_ refs: [AskArtifactRef]) throws {
        guard !refs.isEmpty, refs.count <= 8,
              refs.allSatisfy({ $0.ownerId == identity.ownerId && $0.conversationId == identity.conversationId && $0.runId == identity.runId })
        else { throw AskArtifactError.invalid }
        let encoded = try JSONEncoder().encode(refs)
        guard encoded.count <= 64 * 1024 else { throw AskArtifactError.tooLarge }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false)
        try root.lock()
        let directory = try root.child(id, privateDirectory: true)
        guard try directory.readFile("identity.json", limit: 16 * 1024).decodedIdentity() == identity
        else { throw AskArtifactError.denied }
        try directory.createFile("published.json", data: encoded)
        for name in directory.entries(limit: 16) where name == "response.json" || name.hasPrefix("download-") {
            try directory.remove(name)
        }
    }

    /// Recovery reads are explicit and scope-checked; this never dispatches a provider.
    static func load(rootURL: URL, id: String, scope: AskProjectScope, callId: String) throws -> [String: Data] {
        guard id.count == 64, id.allSatisfy(\.isHexDigit) else { throw AskArtifactError.invalid }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false)
        try root.lock()
        let directory = try root.child(id, privateDirectory: true)
        let identity = try directory.readFile("identity.json", limit: 16 * 1024).decodedIdentity()
        guard identity == Identity(ownerId: scope.ownerId, conversationId: scope.conversationId, runId: scope.runId, callId: callId)
        else { throw AskArtifactError.denied }
        var result: [String: Data] = [:], total = 0
        for name in directory.entries(limit: 16) {
            let limit: Int
            if name == "response.json" { limit = AskImageGenerationService.maximumResponseBytes }
            else if (0..<8).contains(where: { name == "download-\($0)" }) { limit = AskArtifactStore.maximumFileBytes }
            else if ["request.json", "identity.json", "published.json"].contains(name) { limit = 64 * 1024 }
            else { throw AskArtifactError.corrupt }
            let data = try directory.readFile(name, limit: limit)
            total += data.count
            guard total <= 78 * 1024 * 1024 + 192 * 1024 else { throw AskArtifactError.tooLarge }
            result[name] = data
        }
        return result
    }

    static func delete(rootURL: URL, ownerId: String, conversationId: String) throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false)
        try root.lock()
        for name in root.entries(limit: maximumRecords) {
            guard let directory = try? root.child(name, privateDirectory: true),
                  let identity = try? directory.readFile("identity.json", limit: 16 * 1024).decodedIdentity(),
                  identity.ownerId == ownerId, identity.conversationId == conversationId else { continue }
            try root.remove(name)
        }
    }
}

private extension Data {
    func decodedIdentity() throws -> AskImageGenerationRetention.Identity {
        try JSONDecoder().decode(AskImageGenerationRetention.Identity.self, from: self)
    }
}
