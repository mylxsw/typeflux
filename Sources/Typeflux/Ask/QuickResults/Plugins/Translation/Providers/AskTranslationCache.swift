import Darwin
import Foundation

/// Successful API responses are shared by the translation panel and launcher, including across processes.
struct AskTranslationCache: Sendable {
    static let shared = AskTranslationCache(
        directory: TypefluxDataDirectories.cache.appendingPathComponent("translations-v1", isDirectory: true)
    )

    private static let entryLimit = 512
    private static let byteLimit = 16 * 1024 * 1024
    private static let maximumEntrySize = 256 * 1024
    let directory: URL

    static func key(provider: AskTranslationProvider, text: String, source: String?, target: String,
                    credentials: AskTranslationCredentials) -> String {
        AskTranslationSigning.sha256Hex(AskTranslationSigning.formBody([
            ("provider", provider.rawValue), ("text", text), ("source", source ?? ""), ("target", target),
            ("key", credentials.key), ("secret", credentials.secret), ("region", credentials.region)
        ]))
    }

    func translation(for key: String, fetch: () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(key + ".txt")
        if let result = read(url) { return result }

        // Shard the locks to keep their number bounded, and recheck after acquiring one.
        let lock = openLock(shard: key.prefix(2))
        guard lock >= 0 else { return try await fetch() }
        defer { close(lock) }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return try await fetch() }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        if let result = read(url) { return result }

        let result = try await fetch()
        try Task.checkCancellation()
        store(result, at: url)
        return result
    }

    private func openLock(shard: Substring) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return -1
        }
        let path = directory.appendingPathComponent(".lock-\(shard)").path
        return open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }

    private func read(_ url: URL) -> String? {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
              let size = info.fileSize, (1 ... Self.maximumEntrySize).contains(size),
              let result = try? String(contentsOf: url, encoding: .utf8),
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    private func store(_ result: String, at url: URL) {
        let data = Data(result.utf8)
        guard data.count <= Self.maximumEntrySize,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            trim()
        } catch { /* Translation can still succeed when its disposable cache is unavailable. */ }
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        ) else { return }
        let entries = files.filter { $0.pathExtension == "txt" }.compactMap { url -> (URL, Int, Date)? in
            guard let info = try? url.resourceValues(forKeys: keys), let size = info.fileSize,
                  let date = info.contentModificationDate else { return nil }
            return (url, size, date)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0
        for (index, (url, size, _)) in entries.enumerated() {
            if index >= Self.entryLimit || size > Self.byteLimit - bytes {
                try? FileManager.default.removeItem(at: url)
            } else {
                bytes += size
            }
        }
    }
}
