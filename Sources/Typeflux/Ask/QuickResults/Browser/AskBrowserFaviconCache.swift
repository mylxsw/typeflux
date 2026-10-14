import AppKit
import ImageIO

/// Icons are optional: their bounded, cookie-free requests never delay tab search.
@MainActor
final class AskBrowserFaviconCache {
    private struct Pending {
        let id: UUID
        let task: Task<Data?, Never>
        var clients: Set<UUID>
    }

    typealias Loader = @Sendable (URL) async -> Data?
    static let shared = AskBrowserFaviconCache()
    private let images = NSCache<NSURL, NSImage>()
    private var failures: [URL: Date] = [:]
    private var pending: [URL: Pending] = [:]
    private let loader: Loader
    private let clock: () -> Date

    init(loader: @escaping Loader = { await AskBrowserFaviconCache.load($0) },
         clock: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.clock = clock
        images.countLimit = 256
    }

    /// Only the origin is sent to the website; tab paths, queries and credentials stay local.
    nonisolated static func faviconURL(for text: String) -> URL? {
        guard var parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        parts.user = nil
        parts.password = nil
        parts.path = "/favicon.ico"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    func cached(_ url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(_ url: URL) async -> NSImage? {
        guard !Task.isCancelled, Self.faviconURL(for: url.absoluteString) == url else { return nil }
        if let image = cached(url) {
            return image
        }
        if let failure = failures[url], clock().timeIntervalSince(failure) < 60 {
            return nil
        }
        let client = UUID()
        let entry: Pending
        if var existing = pending[url] {
            existing.clients.insert(client)
            entry = existing
        } else {
            entry = Pending(id: UUID(), task: Task { await loader(url) }, clients: [client])
        }
        pending[url] = entry
        return await withTaskCancellationHandler {
            let data = await entry.task.value
            defer { release(url, id: entry.id, client: client) }
            guard !Task.isCancelled, pending[url]?.id == entry.id else { return nil }
            if let image = cached(url) {
                return image
            }
            guard let data, let image = Self.decode(data) else {
                failures = failures.filter { clock().timeIntervalSince($0.value) < 60 }
                if failures.count >= 256 {
                    failures.removeAll()
                }
                failures[url] = clock()
                return nil
            }
            failures[url] = nil
            images.setObject(image, forKey: url as NSURL)
            return image
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(url, id: entry.id, client: client) }
        }
    }

    private func release(_ url: URL, id: UUID, client: UUID) {
        guard var entry = pending[url], entry.id == id, entry.clients.remove(client) != nil else { return }
        if entry.clients.isEmpty {
            pending[url] = nil
            entry.task.cancel()
        } else {
            pending[url] = entry
        }
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard data.count <= 262_144,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 56,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .init(width: 26, height: 26))
    }

    nonisolated static func load(_ url: URL, transport: any AskImageTransport = AskImageHTTP()) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 3)
        return try? await transport.send(request, limit: 262_144)
    }
}
