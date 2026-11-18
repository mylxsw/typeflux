import CryptoKit
import Darwin
import Foundation

/// Original bytes only; every cache hit still passes through the isolated decoder.
actor AskGeneratedImageCache {
    static let shared = AskGeneratedImageCache(root: TypefluxDataDirectories.cache.appendingPathComponent("generated-images"))
    static let capacity = 256 * 1024 * 1024
    struct Ticket: Sendable {
        let key: String
        let epoch: String
        let data: Data?
    }
    private struct Pending {
        let id: UUID
        let task: Task<Data, Error>
        var clients: Set<UUID>
    }
    let root: URL
    let capacity: Int
    private var pending: [String: Pending] = [:]

    init(root: URL, capacity: Int = AskGeneratedImageCache.capacity) {
        self.root = root; self.capacity = capacity
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }

    private func epoch() throws -> String {
        let url = root.appendingPathComponent(".epoch")
        if let value = try? String(contentsOf: url, encoding: .utf8) { return value }
        let value = UUID().uuidString
        try Data(value.utf8).write(to: url, options: .atomic)
        return value
    }

    func lookup(owner: String, asset: String, force: Bool = false) throws -> Ticket {
        let encoded = try JSONEncoder().encode([owner, asset])
        let key = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return try locked {
            let generation = try epoch(), url = root.appendingPathComponent(key + ".image")
            var data: Data?
            if !force, let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               info.isRegularFile == true, let size = info.fileSize, size > 0,
               size <= AskRemoteImageLoader.maximumBytes {
                data = try? Data(contentsOf: url)
                if data != nil { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
            }
            return Ticket(key: key, epoch: generation, data: data)
        }
    }

    func remove(_ ticket: Ticket) throws {
        try locked {
            guard try epoch() == ticket.epoch else { return }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(ticket.key + ".image"))
        }
    }

    func store(_ data: Data, ticket: Ticket) throws {
        guard !Task.isCancelled, !data.isEmpty, data.count <= min(capacity, AskRemoteImageLoader.maximumBytes) else { return }
        try locked {
            guard try epoch() == ticket.epoch else { return }
            let url = root.appendingPathComponent(ticket.key + ".image")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let files = try entries().sorted { $0.date < $1.date }
            var total = files.reduce(0) { $0 + $1.size }
            for file in files where total > capacity {
                try FileManager.default.removeItem(at: file.url); total -= file.size
            }
        }
    }

    private func entries() throws -> [(url: URL, size: Int, date: Date)] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "image" }.map {
                let info = try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return ($0, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
            }
    }

    func size() throws -> Int { try locked { try entries().reduce(0) { $0 + $1.size } } }

    func clear() throws {
        try locked {
            try Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent(".epoch"), options: .atomic)
            for file in try entries() { try FileManager.default.removeItem(at: file.url) }
        }
    }

    /// Downloads are shared within a presentation process. The last departing client cancels them.
    func download(ticket: Ticket, fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let key = ticket.epoch + ticket.key, client = UUID()
        let operation: Pending
        if var existing = pending[key] {
            existing.clients.insert(client); pending[key] = existing; operation = existing
        } else {
            operation = Pending(id: UUID(), task: Task { try await fetch() }, clients: [client])
            pending[key] = operation
        }
        defer { release(key: key, id: operation.id, client: client) }
        return try await withTaskCancellationHandler {
            let data = try await operation.task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            Task { await self.release(key: key, id: operation.id, client: client) }
        }
    }

    private func release(key: String, id: UUID, client: UUID) {
        guard var entry = pending[key], entry.id == id else { return }
        entry.clients.remove(client)
        if entry.clients.isEmpty { entry.task.cancel(); pending[key] = nil }
        else { pending[key] = entry }
    }
}
