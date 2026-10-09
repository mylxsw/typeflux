import AppKit
import QuickLookThumbnailing

/// Quick Look supplies file previews; application icons come from their resolved
/// bundles. Filesystem and Finder work runs off the main thread, never in view bodies.
@MainActor
final class AskResultImageCache {
    struct Key: Hashable {
        var url: URL
        var thumbnail: Bool
        var modified: Date?
        var scale: CGFloat = 2
    }

    /// Keep NSImage on MainActor; its Sendable conformance requires macOS 14.
    @MainActor
    private final class LoadedImage {
        let image: NSImage?

        init(_ image: NSImage?) { self.image = image }
    }

    typealias Loader = @MainActor (Key) async -> NSImage?
    static let shared = AskResultImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [Key: (task: Task<LoadedImage, Never>, clients: Set<UUID>)] = [:]
    private let loader: Loader

    init(loader: @escaping Loader = AskResultImageCache.generate) {
        self.loader = loader
        cache.countLimit = 256
    }

    private func cacheKey(_ key: Key) -> NSString {
        "\(key.url.absoluteString)|\(key.thumbnail)|\(key.modified?.timeIntervalSinceReferenceDate ?? 0)|\(key.scale)" as NSString
    }

    func cached(_ key: Key) -> NSImage? { cache.object(forKey: cacheKey(key)) }

    func image(_ key: Key) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = await Self.resolved(key)
        guard !Task.isCancelled else { return nil }
        if let image = cached(key) { return image }
        let client = UUID()
        let task: Task<LoadedImage, Never>
        if var entry = pending[key] {
            entry.clients.insert(client)
            pending[key] = entry
            task = entry.task
        } else {
            task = Task { LoadedImage(await loader(key)) }
            pending[key] = (task, [client])
        }
        return await withTaskCancellationHandler {
            let image = await task.value.image
            if !Task.isCancelled, let image { cache.setObject(image, forKey: cacheKey(key)) }
            release(key, client: client)
            return Task.isCancelled ? nil : image
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(key, client: client) }
        }
    }

    private func release(_ key: Key, client: UUID) {
        guard var entry = pending[key], entry.clients.remove(client) != nil else { return }
        if entry.clients.isEmpty {
            pending[key] = nil
            entry.task.cancel()
        } else {
            pending[key] = entry
        }
    }

    /// Resolve before looking up either the cache or pending requests: aliases share
    /// an icon, while a link retargeted by a macOS update gets a new cache entry.
    private static func resolved(_ key: Key) async -> Key {
        guard key.url.isFileURL, key.url.pathExtension.lowercased() == "app" else { return key }
        let url = await Task.detached(priority: .utility) { [url = key.url] in
            url.resolvingSymlinksInPath()
        }.value
        var resolved = key
        resolved.url = url
        return resolved
    }

    private static func generate(_ key: Key) async -> NSImage? {
        if key.url.isFileURL, key.url.pathExtension.lowercased() == "app" {
            return await AskAppIcon.image(for: key.url)
        }
        let request = QLThumbnailGenerator.Request(fileAt: key.url, size: CGSize(width: 56, height: 56),
                                                   scale: key.scale, representationTypes: key.thumbnail ? .all : .icon)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled,
                  let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                  !Task.isCancelled else { return nil }
            return representation.nsImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}
