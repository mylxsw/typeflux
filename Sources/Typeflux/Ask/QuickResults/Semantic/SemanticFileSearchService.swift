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
    private var downloadAttempt: SemanticDownloadProgressDelivery.Source?
    private let downloadProgress: SemanticDownloadProgressDelivery
    private var rescan: Task<Void, Never>?
    private var countRefresh: Task<Void, Never>?
    private var countRefreshID: UUID?
    private struct CountRefreshRequest {
        let database: SemanticFileStore
        let lifecycle: AskSearchCancellation
        let attempt: SemanticIndexProgressDelivery.Source
    }
    private var pendingCountRefresh: CountRefreshRequest?
    private let progressDelivery: SemanticIndexProgressDelivery
    private let countSnapshot: @Sendable (SemanticFileStore) throws -> SemanticFileStore.Counts
    private var indexAttempt: SemanticIndexProgressDelivery.Source?
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
    private var pendingDirectories = Set<String>()
    private var pendingEventID: UInt64 = 0
    private var committedEventID: UInt64 = 0
    private var volumeSignature: String?
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
         requiresReaderLifecycle: Bool = false, requiresModelLifecycle: Bool = false, deferInitialStart: Bool = false,
         progressDelivery: SemanticIndexProgressDelivery = SemanticIndexProgressDelivery(),
         downloadProgress: SemanticDownloadProgressDelivery = SemanticDownloadProgressDelivery(),
         countSnapshot: @escaping @Sendable (SemanticFileStore) throws -> SemanticFileStore.Counts = { try $0.counts() }) {
        self.progressDelivery = progressDelivery; self.countSnapshot = countSnapshot
        self.downloadProgress = downloadProgress
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

    func rescanAll() { start(force: true, renewReaderAuthorization: true, fullScan: true) }

    private func start(force: Bool, renewReaderAuthorization: Bool, fullScan: Bool = false) {
        guard !removing else { return }
        preferences = settings.semanticFileSearch
        let names = settings.askLauncherSearchSettings
        let key = "\(preferences.enabled)\u{3}\(names.fileIndexFingerprint)\u{3}\(settings.askQuickFileSearchEnabled)"
        guard force || fingerprint != key else { return }
        if renewReaderAuthorization {
            readerAuthorization = readers.authorization()
            embeddingAuthorization = embeddingOwners.authorization()
        }
        dirty = false; pendingPaths.removeAll(); pendingDirectories.removeAll(); _ = pauseGate.takeDocuments()
        pausedIndexing = false; pausedReady = false
        pauseGate.setPaused(backgroundPaused)
        if fingerprint != key || !backgroundPaused {
            indexProgress = nil
        }
        currentProcessingPath = nil
        fingerprint = key
        invalidateIndexProgress()
        cancelDownload()
        let previousDownload = download
        token.cancel(); token = AskSearchCancellation()
        readers.stop(); embeddingOwners.stop()
        let token = token
        let previous = work
        work?.cancel(); rescan?.cancel(); watcher.stop()
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil; queryState = .idle
        scope = nil; store = nil; queryValidator = nil
        guard supported, preferences.enabled,
              settings.askQuickFileSearchEnabled else { phase = .off; return }
        self.mediaDownload = nil; self.mediaFailed = false
        self.phase = .preparing
        let directory = directory, model = self.modelURL, helper = helper, access = access
        let models = models
        self.work = Task { [weak self] in
            await previous?.value
            await previousDownload?.value
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
                    await updateCounts(database, lifecycle: token)
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
                if fullScan { try database.invalidateDiscovery() }
                let latestEventID = AskFSEventsWatcher.currentEventID
                let signature = AskFSEventsWatcher.historySignature(paths: prepared.0.roots)
                self.volumeSignature = signature
                let previousEventID: UInt64?
                if let signature {
                    previousEventID = try database.completedEventID(scope: prepared.0, volumeSignature: signature)
                } else {
                    previousEventID = nil
                }
                let savedEventID = previousEventID.flatMap { $0 <= latestEventID ? $0 : nil }
                let watchEventID = savedEventID ?? latestEventID
                self.committedEventID = watchEventID
                self.pendingEventID = watchEventID
                let prunePending = try savedEventID != nil && database.hasPendingPrune()
                let retryDirectories = savedEventID != nil ? try database.failedDirectories() : []
                watcher.start(paths: prepared.0.roots, since: watchEventID) { [weak self] changes, last in
                    Task { @MainActor in
                        guard !token.isCancelled else { return }
                        self?.receiveChanges(changes, eventID: last)
                    }
                }
                if self.backgroundPaused {
                    guard !token.isCancelled, !Task.isCancelled else { return }
                    self.phase = .paused
                    return
                }
                self.skipped = 0
                self.phase = .indexing
                self.beginIndexing(database, scope: prepared.0, token: token,
                                   paths: savedEventID == nil ? nil : [],
                                   directories: retryDirectories,
                                   scanStartEventID: savedEventID == nil ? watchEventID : nil,
                                   prunePending: prunePending,
                                   processedEventID: savedEventID)

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

    private func invalidateIndexProgress() {
        progressDelivery.invalidate(); indexAttempt = nil
        // Keep the active read's handle until it actually returns; replacement scopes
        // may retain one latest request, never launch parallel refresh readers.
        countRefresh?.cancel(); pendingCountRefresh = nil
    }

    private func updateCounts(_ database: SemanticFileStore, lifecycle: AskSearchCancellation,
                              attempt: SemanticIndexProgressDelivery.Source? = nil) async {
        guard !Task.isCancelled, !lifecycle.isCancelled, fingerprint == settingsFingerprint else { return }
        let cancellation = AskSearchCancellation(), countSnapshot = countSnapshot
        let counts = await withTaskCancellationHandler {
            try? await Task.detached(priority: .utility) {
                guard !lifecycle.isCancelled, !cancellation.isCancelled else { throw CancellationError() }
                return try countSnapshot(database)
            }.value
        } onCancel: { cancellation.cancel() }
        if let counts {
            guard !Task.isCancelled, !lifecycle.isCancelled, !removing, store === database,
                  fingerprint == settingsFingerprint,
                  attempt == nil || indexAttempt === attempt else { return }
            if files != counts.files { files = counts.files }
            if chunks != counts.chunks { chunks = counts.chunks }
            if indexedCounts != counts { indexedCounts = counts }
        }
    }

    private func receiveIndexProgress(_ snapshot: SemanticIndexProgressDelivery.Snapshot,
                                      database: SemanticFileStore, lifecycle: AskSearchCancellation,
                                      attempt: SemanticIndexProgressDelivery.Source) {
        guard !lifecycle.isCancelled, indexAttempt === attempt, !removing,
              fingerprint == settingsFingerprint, phase == .indexing || pausedIndexing else { return }
        if snapshot.hasDownload { mediaDownload = snapshot.download }
        if snapshot.hasPath, snapshot.path == nil || phase == .indexing {
            currentProcessingPath = snapshot.path
        }
        guard let summary = snapshot.summary else { return }
        let priorityChanged = indexProgress?.priorityUpdates != summary.priorityUpdates
        indexProgress = summary
        files = max(files, summary.files); skipped = summary.skipped
        requestCountRefresh(database, lifecycle: lifecycle, attempt: attempt, priorityChanged: priorityChanged)
    }

    private func requestCountRefresh(_ database: SemanticFileStore, lifecycle: AskSearchCancellation,
                                     attempt: SemanticIndexProgressDelivery.Source, priorityChanged: Bool) {
        guard priorityChanged || Date().timeIntervalSince(lastCountRefresh) >= 3 else { return }
        let request = CountRefreshRequest(database: database, lifecycle: lifecycle, attempt: attempt)
        if countRefresh != nil { pendingCountRefresh = request; return }
        startCountRefresh(request)
    }

    private func startCountRefresh(_ request: CountRefreshRequest) {
        lastCountRefresh = Date()
        let id = UUID()
        countRefreshID = id
        countRefresh = Task { [weak self] in
            guard let self else { return }
            await updateCounts(request.database, lifecycle: request.lifecycle, attempt: request.attempt)
            guard countRefreshID == id else { return }
            countRefresh = nil; countRefreshID = nil
            let next = pendingCountRefresh
            pendingCountRefresh = nil
            if let next, !next.lifecycle.isCancelled, indexAttempt === next.attempt {
                startCountRefresh(next)
            }
        }
    }

    private func receiveChanges(_ changes: [AskFileChange], eventID: UInt64) {
        guard let scope else { return }
        pendingEventID = max(pendingEventID, eventID)
        let plan = SemanticFileChangePlan.make(changes, scope: scope, indexDirectory: directory.path)
        if plan.fullScan {
            self.dirty = true; self.pendingPaths.removeAll(); self.pendingDirectories.removeAll()
        } else if !self.dirty {
            self.pendingPaths.formUnion(plan.files)
            self.pendingDirectories.formUnion(plan.directories)
        }
        guard plan.fullScan || !plan.files.isEmpty || !plan.directories.isEmpty ||
            pendingEventID > committedEventID else { return }
        if phase == .indexing || pausedIndexing {
            pauseGate.enqueueDocuments(plan.files.filter { SemanticMediaPriority.of($0) == .document })
        }
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard self.phase != .indexing, !self.backgroundPaused,
              self.dirty || !self.pendingPaths.isEmpty || !self.pendingDirectories.isEmpty ||
              self.pendingEventID > self.committedEventID else { return }
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
            self.start(force: true, renewReaderAuthorization: false, fullScan: true)
            return
        }
        let paths = self.pendingPaths.sorted()
        let directories = self.pendingDirectories.sorted()
        let eventID = self.pendingEventID
        if paths.isEmpty && directories.isEmpty {
            do {
                try database.saveEventID(eventID, scope: scope, volumeSignature: volumeSignature)
                self.committedEventID = eventID
            } catch { self.phase = .failed }
            return
        }
        self.pendingPaths.removeAll()
        self.pendingDirectories.removeAll()
        self.indexProgress = nil
        self.phase = .indexing
        self.beginIndexing(database, scope: scope, token: token, paths: paths,
                           directories: directories, processedEventID: eventID)
    }

    deinit { downloadProgress.invalidate(); progressDelivery.invalidate(); countRefresh?.cancel(); token.cancel(); readers.stop(); embeddingOwners.stop(); work?.cancel(); download?.cancel(); rescan?.cancel(); warmup?.cancel() }
}

extension SemanticFileSearchService {
    /// Do not retain the service while media waits for user idle time.
    private func beginIndexing(_ database: SemanticFileStore, scope: AskFileScope, token: AskSearchCancellation,
                               paths: [String]? = nil, directories: [String] = [],
                               scanStartEventID: UInt64? = nil, prunePending: Bool = false,
                               processedEventID: UInt64? = nil) {
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
        let volumeSignature = volumeSignature
        invalidateIndexProgress()
        let delivery = progressDelivery, attempt = SemanticIndexProgressDelivery.Source()
        indexAttempt = attempt
        delivery.begin(attempt) { [weak self] snapshot in
            self?.receiveIndexProgress(snapshot, database: database, lifecycle: token, attempt: attempt)
        }
        let reportDownload: @Sendable (Double?) -> Void = { delivery.offer(.download($0), from: attempt) }
        let reportProgress: @Sendable (SemanticFileIndexer.Summary) -> Void = { delivery.offer(.summary($0), from: attempt) }
        let reportCurrent: @Sendable (String?) -> Void = { delivery.offer(.path($0), from: attempt) }
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
                            cancelled: { token.isCancelled }, progress: reportProgress,
                            directories: directories, prunePending: prunePending, current: reportCurrent
                        )
                    }
                    return try SemanticFileIndexer.run(scope: scope, store: database, reader: reader,
                                                       encoder: encoder, media: media,
                                                       idle: { idle() && !pauseGate.isPaused },
                                                       paused: { pauseGate.isPaused },
                                                       documents: { pauseGate.takeDocuments() },
                                                       priorityReader: priorityReader,
                                                       cancelled: { token.isCancelled }, progress: reportProgress,
                                                       discovered: {
                                                           if let scanStartEventID {
                                                               try database.saveEventID(scanStartEventID, scope: scope,
                                                                                        volumeSignature: volumeSignature)
                                                           }
                                                       },
                                                       current: reportCurrent)
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                if let processedEventID {
                    try database.saveEventID(processedEventID, scope: scope,
                                             volumeSignature: volumeSignature)
                    self.committedEventID = processedEventID
                } else if let scanStartEventID {
                    self.committedEventID = scanStartEventID
                }
                if let latest = delivery.finish(attempt) {
                    receiveIndexProgress(latest, database: database, lifecycle: token, attempt: attempt)
                }
                self.skipped = result.skipped
                while let refresh = self.countRefresh {
                    await refresh.value
                    guard !token.isCancelled, !Task.isCancelled, indexAttempt === attempt else { return }
                }
                guard !token.isCancelled, !Task.isCancelled, indexAttempt === attempt else { return }
                await self.updateCounts(database, lifecycle: token, attempt: attempt)
                guard !token.isCancelled, !Task.isCancelled, indexAttempt === attempt else { return }
                self.mediaDownload = nil
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
                self.pendingPaths.formUnion(paths ?? [])
                self.pendingDirectories.formUnion(directories)
                if let latest = delivery.finish(attempt) {
                    receiveIndexProgress(latest, database: database, lifecycle: token, attempt: attempt)
                }
                if case SemanticMediaFailure.unavailable = error { self.mediaFailed = true }
                if case SemanticFileStore.Failure.invalidVector = error { self.modelReady = false }
                self.mediaDownload = nil
                self.currentProcessingPath = nil
                self.phase = .failed
            }
        }
    }

    private func ownsDownload(_ attempt: SemanticDownloadProgressDelivery.Source,
                              lifecycle: AskSearchCancellation, fingerprint: String) -> Bool {
        downloadAttempt === attempt && !lifecycle.isCancelled && !removing &&
            fingerprint == settingsFingerprint && preferences.enabled && settings.askQuickFileSearchEnabled
    }

    func downloadModel() {
        guard supported, download == nil, preferences.enabled, !removing,
              !token.isCancelled, fingerprint == settingsFingerprint else { return }
        let mutation: SemanticEmbeddingOwners.Mutation
        do { mutation = try embeddingOwners.mutation(.model) }
        catch { phase = .failed; return }
        let lifecycle = token, installAttempted = AskSearchCancellation()
        let attempt = SemanticDownloadProgressDelivery.Source(), fingerprint = settingsFingerprint
        let target = modelURL, models = models, progress = downloadProgress
        downloadAttempt = attempt
        progress.begin(attempt) { [weak self] fraction in
            guard let self, self.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint),
                  self.download?.isCancelled == false else { return }
            self.phase = .downloading(fraction)
        }
        modelReady = false
        phase = .downloading(0)
        download = Task { [weak self, mutation] in
            // Keep the physical slot and mutation admission until fetch/install really
            // returns, even when cancellation is ignored by the producer.
            defer { mutation.finish() }
            guard let self else { return }
            defer {
                if self.downloadAttempt === attempt {
                    progress.invalidate()
                    self.downloadAttempt = nil; self.download = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard self.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) else { throw CancellationError() }
                let (temporary, response) = try await models.fetch { received in
                    progress.offer(min(1, max(0, Double(received) / Double(SemanticModel.bytes))), from: attempt)
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard self.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) else { throw CancellationError() }
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
                guard self.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) else { throw CancellationError() }
                progress.invalidate()
                mutation.finish()
                self.downloadAttempt = nil; self.download = nil; self.modelReady = true
                self.start(force: true, renewReaderAuthorization: false)
            } catch {
                // A replacement start owns its own preparation/terminal phase. The
                // old attempt may retire its slot, never publish into that lifecycle.
                guard self.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) else { return }
                progress.invalidate()
                self.phase = Task.isCancelled && !installAttempted.isCancelled ? .modelRequired : .failed
            }
        }
    }

    func cancelDownload() {
        downloadProgress.invalidate()
        download?.cancel()
    }

    func prepareModelIfNeeded() async {
        let lifecycle = token, fingerprint = settingsFingerprint
        await self.work?.value
        guard !Task.isCancelled, !lifecycle.isCancelled, fingerprint == settingsFingerprint else { return }
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
        invalidateIndexProgress()
        token.cancel(); work?.cancel(); rescan?.cancel(); cancelDownload(); watcher.stop()
        readers.stop(); embeddingOwners.stop()
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil
        await work?.value; await download?.value; await countRefresh?.value
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
