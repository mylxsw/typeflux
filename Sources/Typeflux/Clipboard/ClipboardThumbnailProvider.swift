import SwiftUI
import TypefluxMediaProtocol

/// No app-lifetime pixel cache. Visible, authorized views own each projection.
enum ClipboardThumbnailProvider {
    static let maximumEdge = 900
    static let listEdge = 240
    private static let admission = AskToolPixelBudget(limit: 2)
    private static let warmupBudget = ClipboardWorkBudget(maximumPending: 1)
    @MainActor static let decodeGate = ClipboardThumbnailDecodeGate()

    /// Capture has already saved the original. Prepare only the small list projection at idle priority.
    static func prepare(_ item: ClipboardItem) {
        prepare([ClipboardFeed.entry(for: item)])
    }

    @discardableResult
    static func prepare(_ entries: [ClipboardEntry],
                        using base: @escaping ClipboardThumbnailDecoding = { try await decode($0, edge: $1) }) -> Task<Void, Never>? {
        let urls = entries.prefix(12).filter { $0.kind == .image || $0.kind == .images }
            .flatMap { $0.contentURLs.prefix(3) }
        guard !urls.isEmpty, let generation = warmupBudget.reserve() else { return nil }
        return Task.detached(priority: .background) {
            defer { warmupBudget.release() }
            for url in urls where warmupBudget.accepts(generation) {
                _ = try? await decodeGate.run(priority: false) {
                    try await base(url, CGFloat(listEdge))
                }
            }
        }
    }

    static func decode(_ url: URL, edge: CGFloat, worker: MediaWorker = .clipboardThumbnails,
                       diskCache: ClipboardThumbnailDiskCache = .shared) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        guard url.isFileURL, url.path.utf8.count <= 4096, !url.path.contains("\0"),
              edge.isFinite, edge >= 1, edge <= CGFloat(maximumEdge) else { throw MediaFailure.invalidProtocol }
        let authorization = worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let slot = try admission.acquire(bytes: 1)
        let pixels = try AskToolPixelBudget.shared.acquire(bytes: Int(edge) * Int(edge) * 4)
        defer { withExtendedLifetime((slot, pixels)) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                if cancellation.isCancelled || !worker.permits(authorization) { throw CancellationError() }
                let options = MediaPreviewOptions(width: Int(edge), height: Int(edge))
                // An extension chooses the adapter, never grants proof that the bytes are valid.
                if ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "heif", "bmp", "ico", "icns", "avif"].contains(url.pathExtension.lowercased()) {
                    let key = diskCache.key(for: url, edge: Int(edge))
                    if let key, let cached = diskCache.read(key, edge: Int(edge)) {
                        guard !cancellation.isCancelled, worker.permits(authorization) else { throw CancellationError() }
                        return cached
                    }
                    let result = try MediaPreviewDisplay.render(url, pixels: .init(width: Int(edge), height: Int(edge)),
                        pdf: false, evidence: nil, cancellation: cancellation, worker: worker)
                    guard !cancellation.isCancelled, worker.permits(authorization) else { throw CancellationError() }
                    if let key { diskCache.write(result, for: key, edge: Int(edge)) }
                    return result
                }
                return try MediaPreviewDisplay.renderQuickLook(.init(path: url.path, representation: .all),
                    options: options, cancellation: cancellation, worker: worker)
            }.value
            try Task.checkCancellation()
            guard worker.permits(authorization) else { throw MediaFailure.unavailable }
            return result
        } onCancel: { cancellation.cancel() }
    }
}

typealias ClipboardThumbnailDecoding = @Sendable (URL, CGFloat) async throws -> AskFilePreviewPDF.Result
private struct ClipboardThumbnailDecoderKey: EnvironmentKey {
    static let defaultValue: ClipboardThumbnailDecoding = { try await ClipboardThumbnailProvider.decode($0, edge: $1) }
}
private struct ClipboardThumbnailCacheKey: EnvironmentKey {
    static let defaultValue: ClipboardThumbnailCache? = nil
}
extension EnvironmentValues {
    var clipboardThumbnailDecoder: ClipboardThumbnailDecoding {
        get { self[ClipboardThumbnailDecoderKey.self] }
        set { self[ClipboardThumbnailDecoderKey.self] = newValue }
    }
    var clipboardThumbnailCache: ClipboardThumbnailCache? {
        get { self[ClipboardThumbnailCacheKey.self] }
        set { self[ClipboardThumbnailCacheKey.self] = newValue }
    }
}

/// Panel-local authorization: a reused entry ID or a new window session cannot bless old pixels.
@MainActor final class ClipboardThumbnailSession: ObservableObject {
    let scope = AskImagePresentationScope()
    let cache = ClipboardThumbnailCache()
    private var cacheEpoch = UUID()
    @Published private(set) var revision = UUID()
    private weak var model: ClipboardPanelModel?
    private var entries: [String: ClipboardEntry] = [:]
    private var active = false
    func begin(_ model: ClipboardPanelModel) {
        end(); self.model = model; entries = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.id, $0) })
        active = true; scope.setVisible(true); revision = UUID()
    }
    func changed(_ publishedEntries: [ClipboardEntry]? = nil) {
        guard let model else { return }
        let next = Dictionary(uniqueKeysWithValues: (publishedEntries ?? model.entries).map { ($0.id, $0) })
        // New rows, recopy dates and pin changes do not alter existing image pixels.
        if entries.contains(where: { id, old in
            guard let current = next[id] else { return true }
            return !Self.sameContent(old, current)
        }) {
            cacheEpoch = cache.clear()
            scope.invalidate()
        }
        entries = next
        revision = UUID()
    }
    func end() {
        active = false; model = nil; entries = [:]
        cacheEpoch = cache.clear(); scope.setVisible(false); revision = UUID()
    }
    func decoder(using base: @escaping ClipboardThumbnailDecoding) -> ClipboardThumbnailDecoding {
        return { [weak self] url, edge in
            guard let self else { throw CancellationError() }
            return try await self.decodeCached(url, edge: edge, using: base)
        }
    }
    private func decodeCached(_ url: URL, edge: CGFloat,
                              using base: @escaping ClipboardThumbnailDecoding) async throws -> AskFilePreviewPDF.Result {
        guard active else { throw CancellationError() }
        return try await cache.decode(url, edge: edge, epoch: cacheEpoch, using: base)
    }
    func access(for entry: ClipboardEntry?) -> AskImagePresentationAccess {
        guard let entry, active else { return .init() }
        return .init(scope: scope, epoch: scope.epoch, authorize: { [weak self] in
            guard let self, active, let model else { return false }
            return model.entries.contains { Self.sameContent($0, entry) }
        })
    }

    private static func sameContent(_ lhs: ClipboardEntry, _ rhs: ClipboardEntry) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.text == rhs.text &&
            lhs.filePaths == rhs.filePaths && lhs.imagePath == rhs.imagePath &&
            lhs.imagePixelSize == rhs.imagePixelSize && lhs.byteSize == rhs.byteSize && lhs.snippet == rhs.snippet
    }
}

/// Queue visible thumbnail work instead of letting requests beyond the media worker's two slots fail.
@MainActor final class ClipboardThumbnailDecodeGate {
    private struct Waiter {
        let id: UUID
        let priority: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int = 2) { self.limit = max(1, limit) }

    func run<T>(priority: Bool, _ operation: () async throws -> T) async throws -> T {
        try await acquire(priority: priority)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(priority: Bool) async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(id: id, priority: priority, continuation: continuation)
                let index = priority ? (waiters.firstIndex { !$0.priority } ?? waiters.count) : waiters.count
                waiters.insert(waiter, at: index)
            }
        }, onCancel: {
            Task { @MainActor in self.cancel(id) }
        })
        if Task.isCancelled { release(); throw CancellationError() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }
}

/// Bounded pixels for this panel presentation. Rows that leave a lazy stack can reuse a finished
/// thumbnail, while closing the panel or changing its entries discards all retained pixels.
@MainActor final class ClipboardThumbnailCache {
    private struct Key: Hashable {
        let url: URL
        let edge: Int
    }
    private struct Pending {
        let id: UUID
        let task: Task<AskFilePreviewPDF.Result, Error>
    }
    private let byteLimit = 40 * 1024 * 1024
    private let itemLimit = 96
    private var generation = UUID()
    private var images: [Key: AskFilePreviewPDF.Result] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private var pending: [Key: Pending] = [:]
    private var pendingOrder: [Key] = []
    private let decodeGate = ClipboardThumbnailProvider.decodeGate

    @discardableResult func clear() -> UUID {
        generation = UUID()
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll(); pendingOrder.removeAll(); images.removeAll(); order.removeAll(); bytes = 0
        return generation
    }

    func decode(_ url: URL, edge: CGFloat, epoch: UUID,
                using base: @escaping ClipboardThumbnailDecoding) async throws -> AskFilePreviewPDF.Result {
        guard epoch == generation, edge.isFinite, edge >= 1, edge <= CGFloat(ClipboardThumbnailProvider.maximumEdge)
        else { throw CancellationError() }
        let key = Key(url: url, edge: Int(edge))
        if let image = images[key] {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
        let work: Pending
        if let current = pending[key] {
            work = current
        } else {
            if pendingOrder.count >= 32 {
                let oldest = pendingOrder.removeFirst()
                pending.removeValue(forKey: oldest)?.task.cancel()
            }
            work = Pending(id: UUID(), task: Task {
                try await decodeGate.run(priority: edge >= 500) {
                    do {
                        return try await base(url, edge)
                    } catch {
                        guard !Task.isCancelled, (error as? MediaFailure) == .unavailable else { throw error }
                        try await Task.sleep(for: .milliseconds(120))
                        return try await base(url, edge)
                    }
                }
            })
            pending[key] = work
            pendingOrder.append(key)
        }
        do {
            let image = try await work.task.value
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            guard pending[key]?.id == work.id || images[key] != nil else { throw CancellationError() }
            pending[key] = nil; pendingOrder.removeAll { $0 == key }
            if images[key] == nil { remember(image, for: key) }
            return image
        } catch {
            if pending[key]?.id == work.id, !Task.isCancelled {
                pending[key] = nil; pendingOrder.removeAll { $0 == key }
            }
            throw error
        }
    }

    func image(for url: URL, edge: CGFloat) -> NSImage? {
        guard edge.isFinite, edge >= 1, edge <= CGFloat(ClipboardThumbnailProvider.maximumEdge) else { return nil }
        let key = Key(url: url, edge: Int(edge))
        guard let result = images[key],
              let raster = result.images.first else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return NSImage(cgImage: raster, size: .zero)
    }

    private func remember(_ image: AskFilePreviewPDF.Result, for key: Key) {
        let size = image.images.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        guard size > 0, size <= byteLimit else { return }
        while bytes + size > byteLimit || order.count >= itemLimit {
            guard !order.isEmpty else { break }
            let removed = order.removeFirst()
            if let old = images.removeValue(forKey: removed) {
                bytes -= old.images.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            }
        }
        images[key] = image; order.append(key); bytes += size
    }
}
