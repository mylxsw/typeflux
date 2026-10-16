import Combine
import Foundation

@MainActor
final class SemanticFileSearchService: ObservableObject, SemanticFileSearching {
    static let shared = SemanticFileSearchService(
        settings: SettingsStore(),
        supported: !AskFileIndex.isTesting && SemanticFilePolicy.supported,
        automaticStart: !AskFileIndex.isTesting,
        requiresReaderLifecycle: true, requiresModelLifecycle: true, deferInitialStart: true
    )
    enum Phase: Equatable { case off, preparing, modelRequired, downloading(Double), indexing, ready, paused, failed }
    @Published private(set) var phase: Phase = .off
    @Published private(set) var files = 0
    @Published private(set) var chunks = 0
    @Published private(set) var indexedCounts = SemanticFileStore.Counts()
    @Published private(set) var skipped = 0
    @Published private(set) var mediaDownload: Double?
    @Published private(set) var mediaFailed = false
    @Published private(set) var indexProgress: SemanticFileIndexer.Summary?
    @Published private(set) var currentProcessingPath: String?
    @Published private(set) var blocked: [String] = []
    @Published private(set) var modelReady = false
    @Published private(set) var preferences: SemanticFileSettings
    let supported: Bool
    enum QueryState: Equatable { case idle, warming, searching, degraded }
    @Published private(set) var queryState: QueryState = .idle
    var isEnabled: Bool {
        supported && preferences.enabled && settings.semanticFileSearch.enabled && settings.askQuickFileSearchEnabled
            && store != nil && scope != nil && (modelReady || chunks > 0) && !removing && fingerprint ==
            settingsFingerprint
    }

    private var settingsFingerprint: String {
        "\(settings.semanticFileSearch.enabled)\u{3}\(settings.askLauncherSearchSettings.fileIndexFingerprint)\u{3}\(settings.askQuickFileSearchEnabled)"
    }
    let settings: SettingsStore
    private let directory: URL
    private let helper: URL
    private let watcher: AskFileWatching
    private let access: @Sendable () -> Bool
    private let lowPowerMode: @Sendable () -> Bool
    private let thermalConstrained: @Sendable () -> Bool
    private let mediaModels: any SemanticModelHandling
    private let idle: @Sendable () -> Bool
    private let makeMediaEncoder: (@Sendable (URL, URL, URL) -> any SemanticMediaEmbedding)?
    private let models: any SemanticModelHandling
    let readers: SemanticFileReaders
    private var readerAuthorization: SemanticFileReaders.Authorization?
    private let makeEncoder: (@Sendable (URL, URL) -> any SemanticEmbedding)?
    private let makeQuery: (@Sendable (URL, URL) -> any SemanticQueryEmbedding)?
    let embeddingOwners: SemanticEmbeddingOwners
    private var embeddingAuthorization: SemanticEmbeddingOwners.Authorization?
    private var observers: [AnyCancellable] = []
    private var work: Task<Void, Never>?
    private var download: Task<Void, Never>?
    private var rescan: Task<Void, Never>?
    private var countRefresh: Task<Void, Never>?
    private var lastCountRefresh = Date.distantPast
    private var token = AskSearchCancellation()
    private var store: SemanticFileStore?
    private var scope: AskFileScope?
    private var warmup: Task<Void, Never>?
    private var prewarmRequested = false
    private var queryGeneration = 0
    private var queryValidator: SemanticFileValidator?
    private var queryWorker: (any SemanticQueryEmbedding)?
    private var fingerprint: String?
    private var busy = false
    private var manuallyPaused = false
    private let pauseGate = SemanticIndexPauseGate()
    private var pausedIndexing = false
    private var pausedReady = false
    private var dirty = false
    private var pendingPaths = Set<String>()
    private var removing = false
    var modelURL: URL {
        self.directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
    }

    var mediaModelURL: URL { directory.appendingPathComponent(SemanticMediaModel.name) }

    init(settings: SettingsStore, directory: URL = SemanticModel.directory, helper: URL = SemanticModel.helperURL,
         supported: Bool = SemanticFilePolicy.supported, watcher: AskFileWatching = AskFSEventsWatcher(),
         access: @escaping @Sendable () -> Bool = { AskFullDiskAccess.isGranted() }, automaticStart: Bool = true,
         lowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         thermalConstrained: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.thermalState.rawValue >= 2 },
         models: any SemanticModelHandling = SemanticModelFiles(),
         mediaModels: any SemanticModelHandling = SemanticMediaModelFiles(),
         idle: @escaping @Sendable () -> Bool = { SemanticMediaIdle.isIdle() },
         makeMediaEncoder: (@Sendable (URL, URL, URL) -> any SemanticMediaEmbedding)? = nil,
         makeReader: (@Sendable () -> any AskFileReading)? = nil,
         makeEncoder: (@Sendable (URL, URL) -> any SemanticEmbedding)? = nil,
         makeQuery: (@Sendable (URL, URL) -> any SemanticQueryEmbedding)? = nil,
         embeddingOwners: SemanticEmbeddingOwners? = nil,
         requiresReaderLifecycle: Bool = false, requiresModelLifecycle: Bool = false, deferInitialStart: Bool = false) {
        self.settings = settings; self.directory = directory; self.helper = helper
        self.supported = supported; self.watcher = watcher; self.access = access
        self.lowPowerMode = lowPowerMode; self.thermalConstrained = thermalConstrained
        self.mediaModels = mediaModels; self.idle = idle; self.makeMediaEncoder = makeMediaEncoder
        self.models = models; self.readers = SemanticFileReaders(makeReader: makeReader, requiresLifecycle: requiresReaderLifecycle)
        self.makeEncoder = makeEncoder; self.makeQuery = makeQuery; self.embeddingOwners = embeddingOwners ?? SemanticEmbeddingOwners(requiresLifecycle: requiresModelLifecycle)
        self.preferences = settings.semanticFileSearch
        guard automaticStart else { return }
        self.observers
            .append(NotificationCenter.default.publisher(for: .askLauncherSearchSettingsDidChange)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.start() }
                })
        self.observers
            .append(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).sink { [weak self] _ in
                Task { @MainActor in self?.refreshPause() }
            })
        self.observers
            .append(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refreshPause() }
                })
        if !deferInitialStart { self.start() }
    }

    private var backgroundPaused: Bool {
        self.busy || self.manuallyPaused || self.lowPowerMode() || self.thermalConstrained()
    }

    func setForegroundBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy
        if busy {
            warmup?.cancel(); warmup = nil; queryWorker?.stop()
            queryState = .idle
        }
        refreshPause()
    }

    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        guard !enabled || (self.supported && self.settings.askQuickFileSearchEnabled) else { return false }
        var next = self.settings.semanticFileSearch
        next.enabled = enabled
        if enabled,
           SemanticFilePolicy.scope(names: self.settings.askLauncherSearchSettings, fullDiskAccess: true).roots
           .isEmpty {
            return false
        }
        self.settings.semanticFileSearch = next
        self.start(force: true)
        return true
    }

    func pause(_ paused: Bool) {
        self.manuallyPaused = paused; self.refreshPause()
    }

    private func refreshPause() {
        let paused = self.backgroundPaused
        self.pauseGate.setPaused(paused)
        if paused {
            if self.phase == .indexing { self.pausedIndexing = true; self.phase = .paused }
            else if self.phase == .ready { self.pausedReady = true; self.phase = .paused }
            return
        }
        guard self.phase == .paused else { return }
        if self.pausedIndexing {
            self.pausedIndexing = false; self.phase = .indexing
        } else if self.pausedReady {
            self.pausedReady = false; self.phase = .ready; self.scheduleReconcile()
        } else {
            self.start(force: true, renewReaderAuthorization: false)
        }
    }

    /// Called once by application startup, never by a health factory or recovery.
    func startForApplication(using registry: ModuleRegistry) async {
        _ = await registry.startAll()
        guard !Task.isCancelled else { return }
        start(force: true)
    }

    // Keep generation checks beside every suspension in this lifecycle transition.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func start(force: Bool = false) { start(force: force, renewReaderAuthorization: true) }

    private func start(force: Bool, renewReaderAuthorization: Bool) {
        guard !removing else { return }
        preferences = settings.semanticFileSearch
        let names = settings.askLauncherSearchSettings
        let key = "\(preferences.enabled)\u{3}\(names.fileIndexFingerprint)\u{3}\(settings.askQuickFileSearchEnabled)"
        guard force || fingerprint != key else { return }
        if renewReaderAuthorization {
            readerAuthorization = readers.authorization()
            embeddingAuthorization = embeddingOwners.authorization()
        }
        dirty = false; pendingPaths.removeAll(); _ = pauseGate.takeDocuments()
        pausedIndexing = false; pausedReady = false
        pauseGate.setPaused(backgroundPaused)
        if fingerprint != key || !backgroundPaused {
            indexProgress = nil
        }
        currentProcessingPath = nil
        fingerprint = key
        token.cancel(); token = AskSearchCancellation()
        readers.stop(); embeddingOwners.stop()
        let token = token
        let previous = work
        work?.cancel(); rescan?.cancel(); watcher.stop()
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil; queryState = .idle
        scope = nil; store = nil; queryValidator = nil
        guard supported, preferences.enabled,
              settings.askQuickFileSearchEnabled else { download?.cancel(); phase = .off; return }
        if download != nil {
            return
        }
        self.mediaDownload = nil; self.mediaFailed = false
        self.phase = .preparing
        let directory = directory, model = self.modelURL, helper = helper, access = access
        let models = models
        self.work = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, !token.isCancelled else { return }
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    guard !token.isCancelled else { throw CancellationError() }
                    let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: access())
                    let database = Result {
                        try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"))
                    }
                    return (scope, database)
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                scope = prepared.0; blocked = prepared.0.blockedInScope
                store = try? prepared.1.get()
                queryValidator = SemanticFileValidator(reader: readers.validation.scope(generation: readerAuthorization?.validation))
                if let database = store {
                    await updateCounts(database)
                }
                guard !token.isCancelled, !Task.isCancelled else { return }
                guard FileManager.default.fileExists(atPath: model.path) else {
                    modelReady = false; phase = .modelRequired; return
                }
                try await Task.detached(priority: .utility) {
                    try models.verify(model, cancelled: { token.isCancelled })
                }.value
                guard !token.isCancelled, !Task.isCancelled else { return }
                modelReady = true
                let database = try prepared.1.get()
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { phase = .failed; return }
                queryWorker = makeQuery?(helper, model) ?? SemanticEmbeddingWorker(
                    helper: helper, model: model, ownership: embeddingOwners.query, authorization: embeddingAuthorization?.query ?? .init(generation: nil), lifecycle: token)
                if prewarmRequested { prepareForSearch() }
                watcher.start(paths: prepared.0.roots, since: nil) { [weak self] changes, _ in
                    Task { @MainActor in
                        guard !token.isCancelled else { return }
                        self?.receiveChanges(changes)
                    }
                }
                if self.backgroundPaused {
                    guard !token.isCancelled, !Task.isCancelled else { return }
                    self.phase = .paused
                    return
                }
                self.skipped = 0
                self.phase = .indexing
                self.beginIndexing(database, scope: prepared.0, token: token)

            } catch {
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                if case SemanticMediaFailure.unavailable = error { self.mediaFailed = true }
                if case SemanticFileStore.Failure.invalidVector = error {
                    self.modelReady = false
                }
                self.phase = .failed
            }
        }
    }

    private func updateCounts(_ database: SemanticFileStore) async {
        if let counts = try? await Task.detached(priority: .utility, operation: { try database.counts() }).value {
            guard !self.removing, self.store === database else { return }
            if self.files != counts.files { self.files = counts.files }
            if self.chunks != counts.chunks { self.chunks = counts.chunks }
            if self.indexedCounts != counts { self.indexedCounts = counts }
        }
    }

    private func receiveChanges(_ changes: [AskFileChange]) {
        guard let scope else { return }
        let plan = SemanticFileChangePlan.make(changes, scope: scope, indexDirectory: directory.path)
        if plan.fullScan {
            self.dirty = true; self.pendingPaths.removeAll()
        } else if !self.dirty {
            self.pendingPaths.formUnion(plan.files)
        }
        guard plan.fullScan || !plan.files.isEmpty else { return }
        if phase == .indexing || pausedIndexing {
            if plan.fullScan { pauseGate.enqueueDocumentScan() }
            pauseGate.enqueueDocuments(plan.files.filter { SemanticMediaPriority.of($0) == .document })
        }
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard self.phase != .indexing, !self.backgroundPaused,
              self.dirty || !self.pendingPaths.isEmpty else { return }
        self.rescan?.cancel()
        self.rescan = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.reconcilePending()
        }
    }

    private func reconcilePending() {
        guard !self.backgroundPaused, self.phase == .ready || self.phase == .failed,
              readerAuthorization?.allowsIndexing(in: readers) == true,
              let database = self.store, let scope = self.scope else { return }
        if self.dirty {
            self.start(force: true, renewReaderAuthorization: false)
            return
        }
        let paths = self.pendingPaths.sorted()
        guard !paths.isEmpty else { return }
        self.pendingPaths.removeAll()
        self.indexProgress = nil
        self.phase = .indexing
        self.beginIndexing(database, scope: scope, token: token, paths: paths)
    }

    deinit { token.cancel(); readers.stop(); embeddingOwners.stop(); work?.cancel(); download?.cancel(); rescan?.cancel(); warmup?.cancel() }
}

extension SemanticFileSearchService {
    /// Do not retain the service while media waits for user idle time.
    private func beginIndexing(_ database: SemanticFileStore, scope: AskFileScope, token: AskSearchCancellation,
                               paths: [String]? = nil) {
        let makeEncoder = makeEncoder, mediaModels = mediaModels, embeddingOwners = embeddingOwners
        let embeddingAuthorization = embeddingAuthorization
        // Capture scopes before scheduling: an obsolete detached job must never
        // mint a new reader generation after a newer service transition.
        let reader = readers.indexing.scope(generation: readerAuthorization?.indexing)
        let priorityReader = readers.priority.scope(generation: readerAuthorization?.priority)
        let makeMediaEncoder: SemanticMediaWorker.Factory = self.makeMediaEncoder ?? { helper, model, projector in
            SemanticEmbeddingWorker(helper: helper, model: model, indexing: true, projector: projector,
                timeout: 90, startupTimeout: 180, ownership: embeddingOwners.media, authorization: embeddingAuthorization?.media ?? .init(generation: nil), lifecycle: token)
        }
        let helper = helper, model = modelURL
        let projector = mediaModelURL, idle = idle, pauseGate = pauseGate
        let reportDownload: @Sendable (Double?) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, !token.isCancelled else { return }
                self.mediaDownload = fraction
            }
        }
        let reportProgress: @Sendable (SemanticFileIndexer.Summary) -> Void = { [weak self] summary in
            Task { @MainActor [weak self] in
                guard let self, !token.isCancelled else { return }
                let priorityChanged = indexProgress?.priorityUpdates != summary.priorityUpdates
                indexProgress = summary
                files = max(files, summary.files); skipped = summary.skipped
                if countRefresh == nil, priorityChanged || Date().timeIntervalSince(lastCountRefresh) >= 3 {
                    lastCountRefresh = Date()
                    countRefresh = Task { [weak self] in
                        guard let self else { return }
                        await self.updateCounts(database)
                        self.countRefresh = nil
                    }
                }
            }
        }
        let reportCurrent: @Sendable (String?) -> Void = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, !token.isCancelled, self.phase == .indexing else { return }
                if self.currentProcessingPath != path {
                    self.currentProcessingPath = path
                }
            }
        }
        self.work = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    defer { reader.stop(); priorityReader.stop() }
                    guard !token.isCancelled else { throw CancellationError() }
                    let encoder = makeEncoder?(helper, model) ?? SemanticEmbeddingWorker(
                        helper: helper, model: model, indexing: true, ownership: embeddingOwners.indexing, authorization: embeddingAuthorization?.indexing ?? .init(generation: nil), lifecycle: token)
                    defer { encoder.release() }
                    let media = SemanticMediaWorker(helper: helper, model: model, projector: projector,
                        models: mediaModels, makeEncoder: makeMediaEncoder, progress: reportDownload,
                        embeddingOwners: embeddingOwners, authorization: embeddingAuthorization?.media ?? .init(generation: nil))
                    if let paths {
                        return try SemanticFileIndexer.reconcile(
                            paths: paths, scope: scope, store: database, reader: reader,
                            encoder: encoder, media: media, idle: { idle() && !pauseGate.isPaused },
                            paused: { pauseGate.isPaused }, documents: { pauseGate.takeDocuments() },
                            priorityReader: priorityReader,
                            cancelled: { token.isCancelled }, progress: reportProgress, current: reportCurrent
                        )
                    }
                    return try SemanticFileIndexer.run(scope: scope, store: database, reader: reader,
                                                       encoder: encoder, media: media,
                                                       idle: { idle() && !pauseGate.isPaused },
                                                       paused: { pauseGate.isPaused },
                                                       documents: { pauseGate.takeDocuments() },
                                                       priorityReader: priorityReader,
                                                       cancelled: { token.isCancelled }, progress: reportProgress,
                                                       current: reportCurrent)
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                self.skipped = result.skipped
                await self.countRefresh?.value
                await self.updateCounts(database)
                guard !token.isCancelled, !Task.isCancelled else { return }
                self.indexProgress = nil
                self.currentProcessingPath = nil
                if self.backgroundPaused {
                    self.pausedIndexing = false
                    self.pausedReady = true
                    self.phase = .paused
                } else {
                    self.phase = .ready
                }
                self.scheduleReconcile()
            } catch {
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                if case SemanticMediaFailure.unavailable = error { self.mediaFailed = true }
                if case SemanticFileStore.Failure.invalidVector = error { self.modelReady = false }
                self.currentProcessingPath = nil
                self.phase = .failed
            }
        }
    }

    func downloadModel() {
        guard self.supported, self.download == nil, self.preferences.enabled, !removing else { return }
        let mutation: SemanticEmbeddingOwners.Mutation
        do { mutation = try embeddingOwners.mutation(.model) }
        catch { phase = .failed; return }
        let lifecycle = token, installAttempted = AskSearchCancellation()
        let target = self.modelURL
        let models = models
        self.modelReady = false
        self.phase = .downloading(0)
        self.download = Task { [weak self, mutation] in
            defer { mutation.finish() }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard !lifecycle.isCancelled else { throw CancellationError() }
                let (temporary, response) = try await models.fetch { [self] received in
                    Task { @MainActor [self] in
                        guard self.download != nil, self.preferences.enabled else { return }
                        self.phase = .downloading(min(1, Double(received) / Double(SemanticModel.bytes)))
                    }
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else { throw URLError(.badServerResponse) }
                let cancellation = AskSearchCancellation()
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        guard !cancellation.isCancelled, !lifecycle.isCancelled else { throw CancellationError() }
                        installAttempted.cancel()
                        try models.install(temporary, to: target, cancelled: { cancellation.isCancelled || lifecycle.isCancelled })
                    }.value
                } onCancel: { cancellation.cancel() }
                try Task.checkCancellation()
                guard !lifecycle.isCancelled else { throw CancellationError() }
                mutation.finish()
                self.download = nil; self.modelReady = true; self.start(force: true, renewReaderAuthorization: false)
            } catch {
                let cancelled = Task.isCancelled
                self.download = nil
                self.phase = !self.preferences.enabled ? .off : (cancelled && !installAttempted.isCancelled ? .modelRequired : .failed)
            }
        }
    }

    func cancelDownload() {
        self.download?.cancel()
    }

    func prepareModelIfNeeded() async {
        await self.work?.value
        if self.phase == .modelRequired {
            self.downloadModel()
        }
    }

    /// Stop every writer before removing artifacts. The name index is never touched.
    func clear(removeModel: Bool = false) async {
        guard !removing else { return }
        removing = true
        _ = setEnabled(false)
        preferences = settings.semanticFileSearch
        token.cancel(); work?.cancel(); rescan?.cancel(); download?.cancel(); watcher.stop()
        readers.stop(); embeddingOwners.stop()
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil
        await work?.value; await download?.value
        let database = store, directory = directory, model = modelURL, projector = mediaModelURL
        let embeddingOwners = embeddingOwners
        do {
            // Revoked native workers retain model ownership through host work and
            // actual collection. A timeout preserves files for an explicit retry.
            try await embeddingOwners.waitUntilIdle()
            try await Task.detached(priority: .utility) {
                let mutation = try embeddingOwners.mutation(.model)
                defer { mutation.finish() }
                if let database {
                    try database.destroy()
                } else {
                    try SemanticFileStore.removeFiles(at: directory.appendingPathComponent("semantic-files.sqlite"))
                }
                if removeModel {
                    for artifact in [model, projector] where FileManager.default.fileExists(atPath: artifact.path) {
                        try FileManager.default.removeItem(at: artifact)
                    }
                }
            }.value
            self.files = 0; self.chunks = 0; self.indexedCounts = .init()
            self.skipped = 0; self.mediaDownload = nil; self.mediaFailed = false
            self.indexProgress = nil; self.phase = .off
            self.currentProcessingPath = nil
            if removeModel {
                self.modelReady = false
            }
        } catch { self.phase = .failed }
        self.store = nil; self.scope = nil; self.queryValidator = nil; self.fingerprint = nil; self.removing = false
    }

    /// Bytes on disk for the content index (database and journal) and the model weights.
    func storage() -> (index: Int64, model: Int64) {
        func size(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let database = self.directory.appendingPathComponent("semantic-files.sqlite")
        let index = ["", "-wal", "-shm"].reduce(Int64(0)) {
            $0 + size(URL(fileURLWithPath: database.path + $1))
        }
        return (index, size(self.modelURL) + size(self.mediaModelURL))
    }

    func processingPage(_ section: SemanticFileStore.ProcessingSection, offset: Int,
                        limit: Int = 50) async -> SemanticFileStore.ProcessingPage? {
        guard let database = store else { return nil }
        return try? await Task.detached(priority: .utility) {
            try database.processingPage(section, offset: offset, limit: limit)
        }.value
    }

    func rebuild() async {
        let scope = self.settings.askLauncherSearchSettings.fileIndexFingerprint
        await self.clear()
        // Scope edits during clearing win; never restore an outdated filename-search scope.
        guard self.phase == .off, self.settings.askLauncherSearchSettings.fileIndexFingerprint == scope else { return }
        _ = self.setEnabled(true)
    }
}

extension SemanticFileSearchService {
    func endSearch() {
        prewarmRequested = false
        warmup?.cancel(); warmup = nil
        if queryState == .warming {
            queryState = .idle
        }
    }

    func prepareForSearch() {
        prewarmRequested = true
        guard isEnabled, !busy, !thermalConstrained(), warmup == nil, let queryValidator, let scope else { return }
        let queryWorker = modelReady ? queryWorker : nil
        let lifecycle = token, preparation = AskSearchCancellation(), gate = pauseGate, store = store
        gate.beginQuery()
        queryState = .warming
        warmup = Task { [weak self] in
            defer { gate.endQuery() }
            do {
                try await withTaskCancellationHandler {
                    async let permissions: Void = Task.detached(priority: .userInitiated) {
                        let stopped = { lifecycle.isCancelled || preparation.isCancelled }
                        try queryValidator.warm(scope: scope, cancelled: stopped)
                        try store?.prepareSearch(cancelled: stopped)
                    }.value
                    try await queryWorker?.prepare(lifecycle: lifecycle)
                    try await permissions
                } onCancel: { preparation.cancel() }
                guard let self, !lifecycle.isCancelled, !Task.isCancelled else { return }
                if queryState == .warming {
                    queryState = .idle
                }
            } catch {
                guard let self, !lifecycle.isCancelled, !Task.isCancelled else { return }
                if queryState == .warming {
                    queryState = .degraded
                }
            }
            self?.warmup = nil
        }
    }

    func search(_ text: String, type: AskFileType = .all, limit: Int = 24) async -> [AskFileHit] {
        await search(text, type: type, limit: limit, progress: { _ in })
    }

    // Keep generation, resource priority and permission checks beside each suspension.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func search(_ text: String, type: AskFileType, limit: Int,
                progress: @escaping @MainActor @Sendable ([AskFileHit]) -> Void) async -> [AskFileHit] {
        guard limit > 0, isEnabled, let query = SemanticFilePolicy.query(text, type: type),
              let store, let scope, let queryValidator else { return [] }
        let lifecycle = token, cancellation = AskSearchCancellation()
        let access = access
        let trace = SemanticSearchTrace.current ?? .init()
        queryGeneration += 1
        let generation = queryGeneration
        let permissionBudgetExpired = AskSearchCancellation()
        func current() -> Bool {
            !lifecycle.isCancelled && !Task.isCancelled && isEnabled
        }
        /// Both channels revalidate every file and current disk permission before publication.
        func retrieve(_ vector: [Float]?) async throws -> [AskFileHit] {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try SemanticSearchTrace.$current.withValue(trace) {
                        let cancelled = { lifecycle.isCancelled || cancellation.isCancelled }
                        var currentScope = scope
                        if !access() {
                            currentScope.blocked = AskFileScope.protectedFolders()
                        }
                        let hits: [AskFileHit]
                        trace.mark(vector == nil ? "fts-start" : "vector-start")
                        if let vector {
                            let semantic = try store.search(vector: vector, text: query, query: AskSearchQuery(text),
                                                            type: type, scope: currentScope,
                                                            limit: min(100, min(100, limit) * 2),
                                                            cancelled: cancelled)
                            hits = semantic
                        } else {
                            hits = try store.lexicalSearch(text: query, query: AskSearchQuery(text), type: type,
                                                           scope: currentScope,
                                                           limit: min(100, min(100, limit) * 2),
                                                           cancelled: cancelled)
                        }
                        trace.mark(vector == nil ? "fts-end" : "vector-end")
                        let valid = queryValidator.validateBatch(hits, scope: currentScope, limit: min(100, limit),
                                                                 cancelled: cancelled)
                        if !valid.complete {
                            permissionBudgetExpired.cancel()
                        }
                        trace.mark("permissions-end")
                        return valid.hits
                    }
                }.value
            } onCancel: { cancellation.cancel() }
        }
        func permitted(_ hits: [AskFileHit]) -> [AskFileHit] {
            var latestScope = scope
            if !access() {
                latestScope.blocked = AskFileScope.protectedFolders()
            }
            return hits.filter { latestScope.includes($0.path, isDirectory: false) }
        }
        func fallback() async -> [AskFileHit] {
            let hits = await (try? retrieve(nil)) ?? []
            return current() ? permitted(hits) : []
        }
        let lexical = await fallback()
        guard current() else { return [] }
        progress(lexical)
        trace.mark("fts-published")
        if generation == queryGeneration, permissionBudgetExpired.isCancelled {
            queryState = .degraded
        }
        guard !permissionBudgetExpired.isCancelled, !busy, !thermalConstrained(), modelReady,
              let queryWorker else { return lexical }
        pauseGate.beginQuery()
        defer {
            pauseGate.endQuery()
            if generation == queryGeneration, queryState == .searching {
                queryState = .idle
            }
        }
        queryState = .searching
        do {
            try await Task.sleep(for: .milliseconds(lowPowerMode() ? 160 : 45))
            guard current() else { return [] }
            guard !busy, !thermalConstrained() else { return await fallback() }
            trace.mark("scheduled")
            let vector = try await queryWorker.query(query, lifecycle: lifecycle)
            trace.mark("encoded")
            try Task.checkCancellation()
            guard current() else { return [] }
            guard !busy, !thermalConstrained() else { return await fallback() }
            let hits = try await retrieve(vector)
            guard current() else { return [] }
            guard !busy, !thermalConstrained() else { return await fallback() }
            if generation == queryGeneration {
                queryState = permissionBudgetExpired.isCancelled ? .degraded : .idle
            }
            trace.mark("semantic-published")
            return permitted(hits)
        } catch {
            guard current() else { return [] }
            if generation == queryGeneration {
                queryState = .degraded
            }
            return await fallback()
        }
    }
}
