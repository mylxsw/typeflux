import Darwin
import Foundation

enum AskArtifactError: Error, LocalizedError, Equatable {
    case unavailable, denied, invalid, tooLarge, unsupported, corrupt, expired, previewDisabled, dynamicUnavailable

    var errorDescription: String? {
        L("ask.artifact.error." + String(describing: self))
    }
}

struct AskArtifactResource: Codable, Equatable {
    var path: String
    var mediaType: String
    var sizeBytes: Int
    var sha256: String
}

/// Local metadata is never a file URL or an authorization grant.
struct AskArtifactManifest: Codable, Equatable {
    var ref: AskArtifactRef
    var workspace: AskWorkspaceRef?
    var createdAt: Date
    var entry: String
    var resources: [AskArtifactResource]
}

struct AskArtifactBundle {
    var manifest: AskArtifactManifest
    var files: [String: Data]
}

/// Immutable, device-only copies. Images persist until deletion; other artifacts expire.
final class AskArtifactStore {
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumBundleBytes = 32 * 1024 * 1024
    static let maximumFiles = 128
    static let maximumStoreEntries = 1024
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    let storageURL: URL
    var now: () -> Date

    init(
        storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/AskArtifacts"),
        now: @escaping () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.now = now
    }

    static func mediaType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "txt", "log", "md", "csv": "text/plain"
        case "css": "text/css"
        case "js": "application/javascript"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        default: "application/octet-stream"
        }
    }

    /// Older image references keep their original wire metadata, but no longer expire locally.
    static func expirationDate(for ref: AskArtifactRef) -> Date? {
        if ref.mediaType.hasPrefix("image/"), ["device_30_days", "device_persistent"].contains(ref.cleanup) {
            return nil
        }
        return ref.expiresAt
    }

    static func validatePath(_ path: String) throws {
        _ = try AskProjectFileAccess.parts(path)
        guard !path.contains("\\"), !path.contains("%"), !path.contains("?"), !path.contains("#") else {
            throw AskArtifactError.invalid
        }
    }

    func publish(files: [String: Data], entry: String, scope: AskProjectScope,
                 workspace: AskWorkspaceRef? = nil) throws -> AskArtifactRef {
        guard ![scope.ownerId, scope.conversationId, scope.runId].contains(where: \.isEmpty),
              workspace.map({ $0.ownerId == scope.ownerId && $0.conversationId == scope.conversationId &&
                      $0.runId == scope.runId }) ?? true else { throw AskArtifactError.denied }
        guard let data = files[entry], !files.isEmpty, files.count <= Self.maximumFiles else {
            throw AskArtifactError.invalid
        }
        var resources: [AskArtifactResource] = [], total = 0, names = Set<String>()
        for path in files.keys.sorted() {
            try Self.validatePath(path)
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw AskArtifactError.invalid
            }
            let bytes = files[path]!
            guard bytes.count <= Self.maximumFileBytes, bytes.count <= Self.maximumBundleBytes - total else {
                throw AskArtifactError.tooLarge
            }
            total += bytes.count
            resources.append(.init(path: path, mediaType: Self.mediaType(path), sizeBytes: bytes.count,
                                   sha256: AskToolPolicy.digest(bytes)))
        }
        // Wire/cache dates use ISO-8601 seconds; preserve exact reference equality after reopening.
        let created = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let persistent = Self.mediaType(entry).hasPrefix("image/")
        let ref = try AskArtifactRef(id: UUID().uuidString.lowercased(), ownerId: scope.ownerId,
                                     conversationId: scope.conversationId, runId: scope.runId,
                                     version: AskToolPolicy.digest(JSONEncoder.sorted.encode(resources)),
                                     mediaType: Self.mediaType(entry), sizeBytes: Int64(data.count),
                                     sha256: AskToolPolicy.digest(data),
                                     cleanup: persistent ? "device_persistent" : "device_30_days",
                                     expiresAt: persistent ? nil : created.addingTimeInterval(Self.retention))
        let manifest = AskArtifactManifest(ref: ref, workspace: workspace, createdAt: created,
                                           entry: entry, resources: resources)
        let root = try AskSecureDirectory.openRoot(storageURL)
        try root.lock()
        guard root.entries(limit: Self.maximumStoreEntries).count < Self.maximumStoreEntries else {
            throw AskArtifactError.tooLarge
        }
        let temporary = ".prepare-" + UUID().uuidString.lowercased()
        let directory = try root.child(temporary, create: true, privateDirectory: true)
        defer { try? root.remove(temporary) }
        // Flat, indexed blobs avoid filesystem aliases and file/directory collisions.
        for (index, resource) in resources.enumerated() {
            try directory.createFile(String(index), data: files[resource.path]!)
        }
        try directory.createFile("manifest.json", data: JSONEncoder.sorted.encode(manifest))
        guard renameat(root.descriptor, temporary, root.descriptor, ref.id) == 0 else {
            throw AskArtifactError.unavailable
        }
        return ref
    }

    func load(_ ref: AskArtifactRef, scope: AskProjectScope,
              authorizeWorkspace: (AskWorkspaceRef) throws -> Void = { _ in throw AskArtifactError.denied }) throws
        -> AskArtifactBundle {
        try withArtifact(ref, scope: scope, authorizeWorkspace: authorizeWorkspace) { manifest, directory in
            let files = try readResources(manifest.resources, from: directory)
            guard let entry = files[manifest.entry], entry.count == ref.sizeBytes,
                  AskToolPolicy.digest(entry) == ref.sha256, Self.mediaType(manifest.entry) == ref.mediaType else {
                throw AskArtifactError.corrupt
            }
            return .init(manifest: manifest, files: files)
        }
    }

    func validate(_ ref: AskArtifactRef, scope: AskProjectScope,
                  authorizeWorkspace: (AskWorkspaceRef) throws -> Void) throws {
        try withArtifact(ref, scope: scope, authorizeWorkspace: authorizeWorkspace) { _, _ in }
    }

    private func withArtifact<T>(
        _ ref: AskArtifactRef, scope: AskProjectScope,
        authorizeWorkspace: (AskWorkspaceRef) throws -> Void,
        body: (AskArtifactManifest, AskSecureDirectory) throws -> T
    ) throws -> T {
        guard UUID(uuidString: ref.id)?.uuidString.lowercased() == ref.id,
              ref.ownerId == scope.ownerId, ref.conversationId == scope.conversationId,
              ref.runId == scope.runId else { throw AskArtifactError.denied }
        let timed = ref.cleanup == "device_30_days" && ref.expiresAt != nil
        let persistent = ref.cleanup == "device_persistent" && ref.expiresAt == nil && ref.mediaType.hasPrefix("image/")
        guard timed || persistent else { throw AskArtifactError.invalid }
        if let expires = Self.expirationDate(for: ref), now() >= expires {
            throw AskArtifactError.expired
        }
        let root: AskSecureDirectory
        let directory: AskSecureDirectory
        do {
            root = try AskSecureDirectory.openRoot(storageURL, create: false)
            try root.lock()
            directory = try root.child(ref.id, privateDirectory: true)
        } catch { throw AskArtifactError.unavailable }
        let manifest = try JSONDecoder().decode(AskArtifactManifest.self,
                                                from: directory.readFile("manifest.json", limit: 256 * 1024))
        guard manifest.ref == ref, !manifest.resources.isEmpty, manifest.resources.count <= Self.maximumFiles,
              try AskToolPolicy.digest(JSONEncoder.sorted.encode(manifest.resources)) == ref.version else {
            throw AskArtifactError.corrupt
        }
        if let workspace = manifest.workspace {
            guard workspace.ownerId == scope.ownerId, workspace.conversationId == scope.conversationId,
                  workspace.runId == scope.runId else { throw AskArtifactError.denied }
            try authorizeWorkspace(workspace)
        }
        return try withExtendedLifetime(root) { try body(manifest, directory) }
    }

    private func readResources(_ resources: [AskArtifactResource],
                               from directory: AskSecureDirectory) throws -> [String: Data] {
        var files: [String: Data] = [:], total = 0
        for (index, resource) in resources.enumerated() {
            try Self.validatePath(resource.path)
            guard resource.sizeBytes >= 0, resource.sizeBytes <= Self.maximumFileBytes,
                  resource.sizeBytes <= Self.maximumBundleBytes - total,
                  files[resource.path] == nil else { throw AskArtifactError.corrupt }
            let data = try directory.readFile(String(index), limit: resource.sizeBytes)
            guard data.count == resource.sizeBytes, AskToolPolicy.digest(data) == resource.sha256,
                  resource.mediaType == Self.mediaType(resource.path) else { throw AskArtifactError.corrupt }
            total += data.count
            files[resource.path] = data
        }
        return files
    }

    /// No workspace paths are ever used for deletion. Corrupt/unknown records are retained.
    func delete(ownerId: String, conversationId: String) throws {
        let root = try AskSecureDirectory.openRoot(storageURL)
        try root.lock()
        for id in root.entries() where UUID(uuidString: id)?.uuidString.lowercased() == id {
            guard let directory = try? root.child(id, privateDirectory: true),
                  let data = try? directory.readFile("manifest.json", limit: 256 * 1024),
                  let manifest = try? JSONDecoder().decode(AskArtifactManifest.self, from: data),
                  manifest.ref.id == id, manifest.ref.ownerId == ownerId,
                  manifest.ref.conversationId == conversationId else { continue }
            try root.remove(id)
        }
    }

    @discardableResult func cleanupExpired() throws -> Int {
        let root = try AskSecureDirectory.openRoot(storageURL)
        try root.lock()
        var removed = 0
        for id in root.entries() where UUID(uuidString: id)?.uuidString.lowercased() == id {
            guard let directory = try? root.child(id, privateDirectory: true),
                  let data = try? directory.readFile("manifest.json", limit: 256 * 1024),
                  let manifest = try? JSONDecoder().decode(AskArtifactManifest.self, from: data),
                  manifest.ref.id == id, manifest.ref.cleanup == "device_30_days",
                  let expiry = Self.expirationDate(for: manifest.ref), expiry <= now() else { continue }
            try root.remove(id)
            removed += 1
        }
        return removed
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
