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
        let entry = generation
        let allowed = access.allows() && access.scope?.visible == true && access.scope?.epoch == access.epoch
        guard !Task.isCancelled, generation == entry else { return false }
        guard allowed, let scope = access.scope, let epoch = access.epoch else {
            let originalAllowed = originalAccess?.allows() == true
            guard !Task.isCancelled, generation == entry else { return false }
            if !originalAllowed { cancel() }
            return false
        }
        if self.epoch == epoch, self.scope === scope {
            let originalAllowed = originalAccess?.allows() == true
            guard !Task.isCancelled, generation == entry else { return false }
            if originalAllowed { return true }
        }
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
        guard hasCurrentAccess(access, generation: generation) else { return nil }
        return images[url]
    }

    /// Access callbacks may retire this owner. Sample its original authority last.
    private func hasCurrentAccess(_ access: AskImagePresentationAccess?, generation current: UUID) -> Bool {
        guard !Task.isCancelled, generation == current else { return false }
        guard let access else { return epoch == nil }
        guard scope === access.scope, epoch == access.epoch else { return false }
        guard access.allows(), !Task.isCancelled, generation == current else { return false }
        guard originalAccess?.allows() == true, !Task.isCancelled, generation == current else { return false }
        return access.scope?.visible == true && access.scope?.epoch == access.epoch
    }

    struct PreparedImage {
        let image: CGImage
        let isCurrent: @MainActor @Sendable () -> Bool
    }
    struct ImagePreparation {
        let image: @MainActor @Sendable () async -> PreparedImage?
        let isCurrent: @MainActor @Sendable () -> Bool
    }

    /// Accept the original source and native snapshot without starting or reserving work.
    func preparation(_ url: URL, access: AskImagePresentationAccess) -> ImagePreparation {
        let original = decode == nil ? worker.authorization() : nil
        let allowed = !Task.isCancelled && url.absoluteString.utf8.count <= 16 * 1024 &&
            Self.faviconURL(for: url.absoluteString) == url && bind(access)
        let currentGeneration = generation
        let current: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return allowed && !Task.isCancelled && self.generation == currentGeneration
        }
        return .init(image: { [self] in
            guard current() else { return nil }
            let result = await preparedImage(url, access: access, authorization: original)
            guard current() else { return nil }
            return result
        }, isCurrent: current)
    }

    func image(_ url: URL, access: AskImagePresentationAccess? = nil) async -> CGImage? {
        await preparedImage(url, access: access)?.image
    }

    private func preparedImage(_ url: URL, access: AskImagePresentationAccess?,
                               authorization original: MediaWorker.Authorization? = nil) async -> PreparedImage? {
        guard !Task.isCancelled, url.absoluteString.utf8.count <= 16 * 1024,
              Self.faviconURL(for: url.absoluteString) == url, bind(access) else { return nil }
        let current = generation
        guard hasCurrentAccess(access, generation: current) else { return nil }
        if let image = images[url] { return .init(image: image, isCurrent: { true }) }
        if let failure = failures[url], clock().timeIntervalSince(failure) < 60 { return nil }
        guard !Task.isCancelled, generation == current else { return nil }
        let client = UUID(), entry: Pending
        if var existing = pending[url] {
            // An older outer consumer cannot adopt a newer pending request after recovery.
            if decode == nil, let original, !worker.permits(original) { return nil }
            guard existing.generation == generation, !existing.task.isCancelled, existing.clients.count < 16 else { return nil }
            existing.clients.insert(client); entry = existing
        } else {
            guard pending.count < 2 else { return nil }
            let authorization = decode == nil ? (original ?? worker.authorization()) : nil
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
            guard !entry.task.isCancelled, hasCurrentAccess(access, generation: entry.generation) else { return nil }
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
            guard let image else { return nil }
            let worker = worker, authorization = entry.authorization
            return .init(image: image, isCurrent: { authorization.map { worker.permits($0) } ?? true })
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
