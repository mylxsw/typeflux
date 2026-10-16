import AppKit

/// Optional origin icons. Pending slots survive cancellation until owned work really returns.
@MainActor
final class AskBrowserFaviconCache: AskImageScopeObserver {
    private struct Pending {
        let id: UUID
        let generation: UUID
        let authorization: MediaWorker.Authorization?
        let task: Task<CGImage?, Never>
        var clients: Set<UUID>
        var completed = false
    }
    typealias Loader = @Sendable (URL) async -> Data?
    typealias Decoder = @Sendable (Data) async throws -> CGImage
    static let shared = AskBrowserFaviconCache()
    private static let downloads = AskToolPixelBudget(limit: 2)
    private var images: [URL: CGImage] = [:]
    private var order: [URL] = []
    private var failures: [URL: Date] = [:]
    private var pending: [URL: Pending] = [:]
    private var generation = UUID()
    private weak var scope: AskImagePresentationScope?
    private var epoch: UUID?
    private var originalAccess: AskImagePresentationAccess?
    private var registration: UUID?
    private let loader: Loader
    private let decode: Decoder?
    private let worker: MediaWorker
    private let clock: () -> Date
    init(loader: @escaping Loader = { await AskBrowserFaviconCache.load($0) },
         clock: @escaping () -> Date = Date.init,
         worker: MediaWorker = .previews, decode: Decoder? = nil) {
        self.loader = loader; self.clock = clock; self.worker = worker; self.decode = decode
    }
    func cancel() {
        generation = UUID(); images.removeAll(); order.removeAll(); failures.removeAll()
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil; epoch = nil; originalAccess = nil
        for key in Array(pending.keys) {
            pending[key]?.clients.removeAll(); pending[key]?.task.cancel()
        }
    }
    private func bind(_ access: AskImagePresentationAccess?) -> Bool {
        guard let access else { return epoch == nil }
        guard access.allows(), let scope = access.scope, let epoch = access.epoch else {
            if self.epoch == access.epoch { cancel() }
            return false
        }
        if self.epoch == epoch, self.scope === scope, originalAccess?.allows() == true { return true }
        cancel()
        guard let registration = try? scope.register(self, epoch: epoch) else { return false }
        self.scope = scope; self.epoch = epoch; self.registration = registration; originalAccess = access
        return true
    }
    /// Only the origin is sent to the website; tab paths, queries and credentials stay local.
    nonisolated static func faviconURL(for text: String) -> URL? {
        guard text.utf8.count <= 16 * 1024, var parts = URLComponents(string: text),
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

    func cached(_ url: URL, access: AskImagePresentationAccess? = nil) -> CGImage? {
        guard access.map({ $0.allows() && originalAccess?.allows() == true && $0.epoch == epoch }) ?? (epoch == nil) else { return nil }
        return images[url]
    }

    func image(_ url: URL, access: AskImagePresentationAccess? = nil) async -> CGImage? {
        guard !Task.isCancelled, url.absoluteString.utf8.count <= 16 * 1024,
              Self.faviconURL(for: url.absoluteString) == url, bind(access) else { return nil }
        if let image = cached(url, access: access) { return image }
        if let failure = failures[url], clock().timeIntervalSince(failure) < 60 { return nil }
        let client = UUID(), entry: Pending
        if var existing = pending[url] {
            guard existing.generation == generation, !existing.task.isCancelled, existing.clients.count < 16 else { return nil }
            existing.clients.insert(client); entry = existing
        } else {
            guard pending.count < 2 else { return nil }
            let authorization = decode == nil ? worker.authorization() : nil
            guard let slot = try? Self.downloads.acquire(bytes: 1) else { return nil }
            let task = Task { [loader, decode, worker] () -> CGImage? in
                defer { withExtendedLifetime(slot) {} }
                guard !Task.isCancelled, authorization.map({ worker.permits($0) }) ?? true,
                      let data = await loader(url), !Task.isCancelled,
                      authorization.map({ worker.permits($0) }) ?? true,
                      !data.isEmpty, data.count <= 262_144 else { return nil }
                let image: CGImage?
                if let decode { image = try? await decode(data) }
                else { image = try? await AskSmallIconDecoder.decode(.data(data), worker: worker, authorization: authorization) }
                guard let image, !Task.isCancelled, authorization.map({ worker.permits($0) }) ?? true,
                      image.width > 0, image.height > 0, image.width <= 56, image.height <= 56 else { return nil }
                return image
            }
            entry = Pending(id: UUID(), generation: generation, authorization: authorization, task: task, clients: [client])
        }
        pending[url] = entry
        return await withTaskCancellationHandler {
            var image = await entry.task.value
            guard pending[url]?.id == entry.id else { return nil }
            pending[url]?.completed = true
            defer { release(url, id: entry.id, client: client) }
            guard !Task.isCancelled, !entry.task.isCancelled, entry.generation == generation,
                  access?.allows() ?? true else { return nil }
            if let authorization = entry.authorization, !worker.permits(authorization) { image = nil }
            if let image {
                if images[url] == nil {
                    if order.count >= 128 { images[order.removeFirst()] = nil }
                    order.append(url); images[url] = image
                }
                failures[url] = nil
            } else {
                failures = failures.filter { clock().timeIntervalSince($0.value) < 60 }
                if failures.count >= 256 { failures.removeAll() }
                failures[url] = clock()
            }
            return image
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(url, id: entry.id, client: client) }
        }
    }
    private func release(_ url: URL, id: UUID, client: UUID) {
        guard var entry = pending[url], entry.id == id else { return }
        entry.clients.remove(client)
        if entry.clients.isEmpty { entry.task.cancel() }
        if entry.completed, entry.clients.isEmpty { pending[url] = nil }
        else { pending[url] = entry }
    }

    nonisolated static func load(_ url: URL, transport: any AskImageTransport = AskImageHTTP()) async -> Data? {
        guard Self.faviconURL(for: url.absoluteString) == url else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 3)
        return try? await transport.send(request, limit: 262_144)
    }
}
