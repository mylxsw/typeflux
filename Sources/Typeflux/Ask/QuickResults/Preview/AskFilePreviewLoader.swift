import AppKit

/// Metadata is checked before cache lookup, including on a hit whose index timestamp is stale.
@MainActor
final class AskFilePreviewLoader: AskFilePreviewLoading {
    typealias Metadata = @MainActor (AskFileHit, Bool) async throws -> AskFileReadResponse
    typealias Generate = @MainActor (AskFileHit, AskFilePreviewKind, CGSize, AskFileReadResponse) async throws
        -> AskFilePreviewContent
    struct Key: Hashable {
        var path: String
        var modified: Date
        var size: Int64
        var width: Int
        var height: Int
        var evidence: AskFileHit.Evidence?
        var version: String?
    }

    private let metadata: Metadata
    private let generate: Generate
    private let clock: any AskFilePreviewClock
    private let timeout: TimeInterval
    private let countLimit: Int
    private let costLimit: Int
    private var cache: [Key: AskFilePreviewContent] = [:]
    private var order: [Key] = []
    private(set) var cacheCost = 0
    var cacheCount: Int {
        cache.count
    }

    private var task: Task<Void, Never>?
    private var prefetchTasks: [Task<Void, Never>] = []
    private var prefetchDeadline: AskFilePreviewTimer?
    private var deadline: AskFilePreviewTimer?
    private var eviction: AskFilePreviewTimer?
    private var generation = 0
    private var cacheGeneration = 0
    private var pressure: DispatchSourceMemoryPressure?

    init(metadata: @escaping Metadata = AskFilePreviewRenderer.metadata,
         generate: @escaping Generate = { try await AskFilePreviewRenderer.generate($0, kind: $1, pixels: $2, info: $3) },
         clock: any AskFilePreviewClock = AskFilePreviewSystemClock(), timeout: TimeInterval = 3,
         countLimit: Int = 32, costLimit: Int = 64 * 1024 * 1024) {
        self.metadata = metadata; self.generate = generate; self.clock = clock; self.timeout = timeout
        self.countLimit = countLimit; self.costLimit = costLimit
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in Task { @MainActor in self?.clearCache() } }
        pressure.resume()
        self.pressure = pressure
    }

    func load(_ hit: AskFileHit, pixels: CGSize, completion: @escaping (AskFilePreviewContent?) -> Void) {
        cancel()
        let ticket = generation
        deadline = clock.schedule(after: timeout) { [weak self] in
            guard let self, generation == ticket else { return }
            cancel()
            completion(nil)
        }
        task = Task { [weak self] in
            guard let self else { return }
            let result = try? await content(hit, pixels: pixels)
            guard !Task.isCancelled, generation == ticket else { return }
            deadline?.cancel(); deadline = nil; task = nil
            completion(result)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        deadline?.cancel(); deadline = nil
        prefetchTasks.forEach { $0.cancel() }; prefetchTasks = []
        prefetchDeadline?.cancel(); prefetchDeadline = nil
    }

    func prefetch(_ hits: [AskFileHit], pixels: CGSize) {
        prefetchTasks.forEach { $0.cancel() }; prefetchTasks = []
        prefetchDeadline?.cancel(); prefetchDeadline = nil
        for hit in hits.prefix(2) where AskFilePreviewPolicy.kind(for: hit)?.canPrefetch == true {
            prefetchTasks.append(Task(priority: .background) { [weak self] in
                _ = try? await self?.content(hit, pixels: pixels)
            })
        }
        prefetchDeadline = clock.schedule(after: timeout) { [weak self] in
            self?.prefetchTasks.forEach { $0.cancel() }; self?.prefetchTasks = []
        }
    }

    func setVisible(_ visible: Bool) {
        eviction?.cancel(); eviction = nil
        if !visible {
            cancel()
            eviction = clock.schedule(after: 60) { [weak self] in self?.clearCache() }
        }
    }

    func clearCache() {
        cacheGeneration += 1
        cache.removeAll(); order.removeAll(); cacheCost = 0
        prefetchTasks.forEach { $0.cancel() }; prefetchTasks = []
        prefetchDeadline?.cancel(); prefetchDeadline = nil
    }

    private func content(_ hit: AskFileHit, pixels: CGSize) async throws -> AskFilePreviewContent {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width >= 1, pixels.height >= 1,
              pixels.width <= 4096, pixels.height <= 4096 else { throw AskFileReadError.unavailable }
        guard let kind = AskFilePreviewPolicy.kind(for: hit) else { throw AskFileReadError.unavailable }
        let cacheTicket = cacheGeneration
        let info = try await metadata(hit, kind.readsText)
        try Task.checkCancellation()
        guard info.error == nil, info.skippedMounts?.isEmpty != false,
              let size = info.fileSize, let modified = info.modified else { throw AskFileReadError.unavailable }
        let key = Key(
            path: hit.path,
            modified: modified,
            size: size,
            width: Int(pixels.width),
            height: Int(pixels.height),
            evidence: hit.evidence,
            version: info.version
        )
        if let cached = cache[key] {
            touch(key); return cached
        }
        var result = try await generate(hit, kind, pixels, info)
        try Task.checkCancellation()
        if info.version != nil {
            let current = try await metadata(hit, false)
            try Task.checkCancellation()
            guard current.error == nil, current.skippedMounts?.isEmpty != false,
                  current.version == info.version else { throw AskFileReadError.unavailable }
        }
        result.fileSize = size
        if let width = info.imageWidth, let height = info.imageHeight {
            result.imageSize = CGSize(width: width, height: height)
        }
        if cacheTicket == cacheGeneration {
            insert(result, for: key)
        }
        return result
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }; order.append(key)
    }

    private func insert(_ content: AskFilePreviewContent, for key: Key) {
        // Discard obsolete versions of the same path instead of retaining many edits.
        for old in order.filter({ $0.path == key.path }) {
            remove(old)
        }
        guard content.cost <= costLimit, countLimit > 0 else { return }
        while !order.isEmpty, cache.count >= countLimit || cacheCost + content.cost > costLimit {
            remove(order[0])
        }
        cache[key] = content; cacheCost += content.cost; touch(key)
    }

    private func remove(_ key: Key) {
        cacheCost -= cache.removeValue(forKey: key)?.cost ?? 0; order.removeAll { $0 == key }
    }

    deinit { pressure?.cancel(); task?.cancel(); prefetchTasks.forEach { $0.cancel() } }
}
