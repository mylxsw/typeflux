import Combine
import Foundation

@MainActor
final class SemanticFileSearchService: ObservableObject, SemanticFileSearching {
    static let shared = SemanticFileSearchService(
        settings: SettingsStore(),
        supported: !AskFileIndex.isTesting && SemanticFilePolicy.supported,
        automaticStart: !AskFileIndex.isTesting
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
    @Published private(set) var blocked: [String] = []
    @Published private(set) var modelReady = false
    @Published private(set) var preferences: SemanticFileSettings
    let supported: Bool
    var isEnabled: Bool {
        supported && preferences.enabled && settings.askQuickFileSearchEnabled && modelReady
            && store != nil && queryWorker != nil && !removing
            && ([Phase.ready, .indexing].contains(phase) || (phase == .failed && mediaFailed))
    }
    let settings: SettingsStore
    private let directory: URL
    private let helper: URL
    private let watcher: AskFileWatching
    private let access: @Sendable () -> Bool
    private let resourceConstrained: @Sendable () -> Bool
    private let mediaModels: any SemanticModelHandling
    private let idle: @Sendable () -> Bool
    private let makeMediaEncoder: @Sendable (URL, URL, URL) -> any SemanticMediaEmbedding
    private let models: any SemanticModelHandling
    private let makeReader: @Sendable () -> any AskFileReading
    private let makeEncoder: @Sendable (URL, URL) -> any SemanticEmbedding
    private let makeQuery: @Sendable (URL, URL) -> any SemanticQueryEmbedding
    private var observers: [AnyCancellable] = []
    private var work: Task<Void, Never>?
    private var download: Task<Void, Never>?
    private var rescan: Task<Void, Never>?
    private var countRefresh: Task<Void, Never>?
    private var lastCountRefresh = Date.distantPast
    private var token = AskSearchCancellation()
    private var store: SemanticFileStore?
    private var scope: AskFileScope?
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
         resourceConstrained: @escaping @Sendable () -> Bool = {
             ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= 2
         },
         models: any SemanticModelHandling = SemanticModelFiles(),
         mediaModels: any SemanticModelHandling = SemanticMediaModelFiles(),
         idle: @escaping @Sendable () -> Bool = { SemanticMediaIdle.isIdle() },
         makeMediaEncoder: @escaping @Sendable (URL, URL, URL) -> any SemanticMediaEmbedding = {
             SemanticEmbeddingWorker(helper: $0, model: $1, indexing: true, projector: $2,
                                     timeout: 90, startupTimeout: 180)
         },
         makeReader: @escaping @Sendable () -> any AskFileReading = { AskFileReader() },
         makeEncoder: @escaping @Sendable (URL, URL) -> any SemanticEmbedding = { SemanticEmbeddingWorker(
             helper: $0,
             model: $1,
             indexing: true
         ) },
         makeQuery: @escaping @Sendable (URL, URL) -> any SemanticQueryEmbedding = { SemanticEmbeddingWorker(
             helper: $0,
             model: $1
         ) }) {
        self.settings = settings; self.directory = directory; self.helper = helper
        self.supported = supported; self.watcher = watcher; self.access = access
        self.resourceConstrained = resourceConstrained
        self.mediaModels = mediaModels; self.idle = idle; self.makeMediaEncoder = makeMediaEncoder
        self.models = models; self.makeReader = makeReader; self.makeEncoder = makeEncoder; self.makeQuery = makeQuery
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
        self.start()
    }

    private var backgroundPaused: Bool {
        self.busy || self.manuallyPaused || self.resourceConstrained()
    }

    func setForegroundBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy
        self.refreshPause()
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
            self.start(force: true)
        }
    }

    // Keep generation checks beside every suspension in this lifecycle transition.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func start(force: Bool = false) {
        guard !self.removing else { return }
        preferences = self.settings.semanticFileSearch
        let names = self.settings.askLauncherSearchSettings
        let key = "\(preferences.enabled)\u{3}\(names.fileIndexFingerprint)\u{3}\(self.settings.askQuickFileSearchEnabled)"
        guard force || self.fingerprint != key else { return }
        self.dirty = false; self.pendingPaths.removeAll()
        self.pausedIndexing = false; self.pausedReady = false
        self.pauseGate.setPaused(self.backgroundPaused)
        if self.fingerprint != key || !self.backgroundPaused { self.indexProgress = nil }
        self.fingerprint = key
        token.cancel(); token = AskSearchCancellation()
        let token = token
        let previous = self.work
        self.work?.cancel(); self.rescan?.cancel(); self.watcher.stop()
        self.queryWorker?.stop(); self.queryWorker = nil
        self.scope = nil
        guard self.supported, preferences.enabled,
              self.settings.askQuickFileSearchEnabled else { self.download?.cancel(); self.phase = .off; return }
        if self.download != nil {
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
                    guard FileManager.default.fileExists(atPath: model.path) else {
                        return (scope, Optional<Result<SemanticFileStore, Error>>.none)
                    }
                    try models.verify(model, cancelled: { token.isCancelled })
                    let database = Result {
                        try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"))
                    }
                    return (scope, Optional(database))
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                self.scope = prepared.0; self.blocked = prepared.0.blockedInScope
                guard let databaseResult = prepared.1 else {
                    self.modelReady = false; self.phase = .modelRequired; return
                }
                self.modelReady = true
                let database = try databaseResult.get()
                self.store = database
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { self.phase = .failed; return }
                await self.updateCounts(database)
                guard !token.isCancelled, !Task.isCancelled else { return }
                self.queryWorker = self.makeQuery(helper, model)
                self.watcher.start(paths: prepared.0.roots, since: nil) { [weak self] changes, _ in
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
        self.scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard self.phase != .indexing, !self.backgroundPaused,
              self.dirty || !self.pendingPaths.isEmpty else { return }
        self.rescan?.cancel()
        self.rescan = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.reconcilePending()
        }
    }

    private func reconcilePending() {
        guard !self.backgroundPaused, self.phase == .ready || (self.phase == .failed && self.mediaFailed),
              let database = self.store, let scope = self.scope else { return }
        if self.dirty {
            self.start(force: true)
            return
        }
        let paths = self.pendingPaths.sorted()
        guard !paths.isEmpty else { return }
        self.pendingPaths.removeAll()
        self.indexProgress = nil
        self.phase = .indexing
        self.beginIndexing(database, scope: scope, token: token, paths: paths)
    }

    deinit { token.cancel(); work?.cancel(); download?.cancel(); rescan?.cancel() }
}

extension SemanticFileSearchService {
    /// Do not retain the service while media waits for user idle time.
    private func beginIndexing(_ database: SemanticFileStore, scope: AskFileScope, token: AskSearchCancellation,
                               paths: [String]? = nil) {
        let makeReader = makeReader, makeEncoder = makeEncoder, mediaModels = mediaModels
        let makeMediaEncoder = makeMediaEncoder, helper = helper, model = modelURL
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
                self.indexProgress = summary
                self.files = max(self.files, summary.files); self.skipped = summary.skipped
                if self.countRefresh == nil, Date().timeIntervalSince(self.lastCountRefresh) >= 3 {
                    self.lastCountRefresh = Date()
                    self.countRefresh = Task { [weak self] in
                        guard let self else { return }
                        await self.updateCounts(database)
                        self.countRefresh = nil
                    }
                }
            }
        }
        self.work = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    let reader = makeReader()
                    let encoder = makeEncoder(helper, model)
                    let media = SemanticMediaWorker(helper: helper, model: model, projector: projector,
                        models: mediaModels, makeEncoder: makeMediaEncoder, progress: reportDownload)
                    if let paths {
                        return try SemanticFileIndexer.reconcile(
                            paths: paths, scope: scope, store: database, reader: reader,
                            encoder: encoder, media: media, idle: { idle() && !pauseGate.isPaused },
                            paused: { pauseGate.isPaused },
                            cancelled: { token.isCancelled }, progress: reportProgress
                        )
                    }
                    return try SemanticFileIndexer.run(scope: scope, store: database, reader: reader,
                                                       encoder: encoder, media: media,
                                                       idle: { idle() && !pauseGate.isPaused },
                                                       paused: { pauseGate.isPaused },
                                                       cancelled: { token.isCancelled }, progress: reportProgress)
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                self.skipped = result.skipped
                await self.countRefresh?.value
                await self.updateCounts(database)
                guard !token.isCancelled, !Task.isCancelled else { return }
                self.indexProgress = nil
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
                self.phase = .failed
            }
        }
    }

    func search(_ text: String, type: AskFileType = .all, limit: Int = 24) async -> [AskFileHit] {
        guard limit > 0, self.isEnabled,
              !self.removing,
              let query = SemanticFilePolicy.query(text, type: type), let store, let scope,
              let queryWorker else { return [] }
        let lifecycle = self.token, access = access, makeReader = makeReader
        do {
            try await Task.sleep(for: .milliseconds(160))
            let vector = try await queryWorker.query(query, lifecycle: lifecycle)
            try Task.checkCancellation()
            let cancellation = AskSearchCancellation()
            let results = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    let cancelled = { lifecycle.isCancelled || cancellation.isCancelled }
                    var currentScope = scope
                    // Full Disk Access can be revoked while an index remains on disk.
                    if !access() {
                        currentScope.blocked = AskFileScope.protectedFolders()
                    }
                    let hits = try store.search(vector: vector, text: query, query: AskSearchQuery(text), type: type,
                                                scope: currentScope, limit: min(100, min(100, limit) * 2),
                                                cancelled: cancelled)
                    let reader = makeReader()
                    return Array(hits.filter { hit in
                        guard !cancelled(), let response = try? reader.read(
                            .init(operation: .content, path: hit.path,
                                  scope: currentScope, readText: false),
                            isCancelled: cancelled
                        ) else { return false }
                        return response.error == nil && response.modified == hit.modified
                    }.prefix(max(0, limit)))
                }.value
            } onCancel: { cancellation.cancel() }
            guard !lifecycle.isCancelled, !Task.isCancelled else { return [] }
            return results
        } catch {
            if !lifecycle.isCancelled, !Task.isCancelled {
                self.phase = .failed
            }
            return []
        }
    }

    func downloadModel() {
        guard self.supported, self.download == nil, self.preferences.enabled else { return }
        let target = self.modelURL
        let models = models
        self.phase = .downloading(0)
        self.download = Task { [weak self] in
            guard let self else { return }
            do {
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
                        try models.install(temporary, to: target, cancelled: { cancellation.isCancelled })
                    }.value
                } onCancel: { cancellation.cancel() }
                try Task.checkCancellation()
                self.download = nil; self.modelReady = true; self.start(force: true)
            } catch {
                let cancelled = Task.isCancelled
                self.download = nil
                self.phase = !self.preferences.enabled ? .off : (cancelled ? .modelRequired : .failed)
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
        guard !self.removing else { return }
        self.removing = true
        _ = self.setEnabled(false)
        self.preferences = self.settings.semanticFileSearch
        self.token.cancel(); self.work?.cancel(); self.rescan?.cancel(); self.download?.cancel(); self.watcher.stop()
        self.queryWorker?.stop(); self.queryWorker = nil
        await self.work?.value; await self.download?.value
        let database = self.store, directory = directory, model = self.modelURL, projector = self.mediaModelURL
        do {
            try await Task.detached(priority: .utility) {
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
            if removeModel {
                self.modelReady = false
            }
        } catch { self.phase = .failed }
        self.store = nil; self.scope = nil; self.fingerprint = nil; self.removing = false
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

    func rebuild() async {
        let scope = self.settings.askLauncherSearchSettings.fileIndexFingerprint
        await self.clear()
        // Scope edits during clearing win; never restore an outdated filename-search scope.
        guard self.phase == .off, self.settings.askLauncherSearchSettings.fileIndexFingerprint == scope else { return }
        _ = self.setEnabled(true)
    }
}
