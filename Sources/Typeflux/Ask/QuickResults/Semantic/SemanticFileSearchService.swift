// swiftlint:disable file_length
// Connection/cache and lifecycle ownership remain private to this implementation.
import Combine
import Foundation

@MainActor
// swiftlint:disable:next type_body_length
final class SemanticFileSearchService: ObservableObject, SemanticFileSearching {
    static let shared = SemanticFileSearchService(
        settings: SettingsStore(),
        supported: !AskFileIndex.isTesting && SemanticFilePolicy.supported,
        automaticStart: !AskFileIndex.isTesting,
        requiresReaderLifecycle: true, requiresModelLifecycle: true, deferInitialStart: true, remote: FeatureProcess.enabled && FeatureProcess.role != .background
    )
    enum Phase: Codable, Equatable { case off, preparing, modelRequired, downloading(Double), indexing, ready, paused, failed }
    @Published private(set) var phase: Phase = .off
    @Published private(set) var files = 0
    @Published private(set) var chunks = 0
    @Published private(set) var hasPublishedContent = false
    @Published private(set) var indexedCounts = SemanticFileStore.Counts()
    @Published private(set) var skipped = 0
    @Published private(set) var mediaDownload: Double?
    @Published private(set) var mediaFailed = false
    @Published private(set) var resourceWaitReason: SemanticWorkBudget.Waiting?
    @Published private(set) var diagnostics: SemanticIndexDiagnostics?
    @Published private(set) var indexProgress: SemanticFileIndexer.Summary?
    @Published private(set) var currentProcessingPath: String?
    @Published private(set) var blocked: [String] = []
    @Published private(set) var modelReady = false
    @Published private(set) var preferences: SemanticFileSettings
    let supported: Bool
    enum QueryState: Codable, Equatable { case idle, warming, searching, degraded }
    @Published private(set) var queryState: QueryState = .idle
    private let remote: Bool
    private var remoteEnabled = false
    var isEnabled: Bool {
        if remote { return remoteEnabled && settings.semanticFileSearch.enabled && settings.askQuickFileSearchEnabled }
        return !stopped && supported && preferences.enabled && settings.semanticFileSearch.enabled && settings.askQuickFileSearchEnabled
            && store != nil && scope != nil && (modelReady || hasPublishedContent) && !removing && fingerprint ==
            settingsFingerprint
    }

    private var settingsFingerprint: String {
        settings.semanticScopeFingerprint()
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
    private let watcherDelivery: SemanticWatcherDelivery
    private let eventHistory: @Sendable ([String]) -> (UInt64, String?)
    private let progressDelivery: SemanticIndexProgressDelivery
    private let countSnapshot: @Sendable (SemanticFileStore) throws -> SemanticFileStore.Counts
    private var indexAttempt: SemanticIndexProgressDelivery.Source?
    private var lastCountRefresh = Date.distantPast
    private var token = AskSearchCancellation()
    private let settingsAuthority = SemanticSettingsAuthority()
    private var store: SemanticFileStore?
    private var scope: AskFileScope?
    private var warmup: Task<Void, Never>?
    private var prewarmRequested = false
    private var queryGeneration = 0
    private var queryValidator: SemanticFileValidator?
    private var permissionRecoveryEpoch = AskSearchCancellation()
    private var queryWorker: (any SemanticQueryEmbedding)?
    private var fingerprint: String?
    private var busy = false
    private let budgetEnabled: Bool
    @Published private(set) var manuallyPaused = false
    private let pauseGate = SemanticIndexPauseGate()
    private lazy var budget = SemanticWorkBudget(enabled: budgetEnabled,
                                                 paused: { [pauseGate] in pauseGate.isPaused }, lowPower: lowPowerMode,
                                                 onWaiting: { [weak self] reason in
                                                     let cancelled = SemanticWorkBudget.cancellation
                                                     Task { @MainActor [weak self] in
                                                         guard cancelled?() != true else { return }
                                                         self?.resourceWaitReason = reason
                                                     }
                                                 })
    private lazy var preparationBudget = SemanticWorkBudget(enabled: budgetEnabled, lowPower: lowPowerMode)
    private var pausedIndexing = false
    private var pausedReady = false
    private var nextReason: SemanticIndexDiagnostics.Reason = .startup
    private var eventJournal: SemanticIndexEvents?
    private var pendingChanges = SemanticFileChangePlan()
    private var pendingProcessingRetry = false
    private var documentSource: SemanticIndexPauseGate.Source?
    private var pendingEventID: UInt64 = 0
    private var committedEventID: UInt64 = 0
    private var volumeSignature: String?
    private var removing = false
    private var stopped = false
    var modelURL: URL {
        directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
    }

    var mediaModelURL: URL {
        directory.appendingPathComponent(SemanticMediaModel.name)
    }

    init(settings: SettingsStore, directory: URL = SemanticModel.directory, helper: URL = SemanticModel.helperURL,
         supported: Bool = SemanticFilePolicy.supported,
         watcher: AskFileWatching = AskFSEventsWatcher(maximumBatchSize: 128),
         access: @escaping @Sendable () -> Bool = { AskFullDiskAccess.isGranted() }, automaticStart: Bool = true,
         budgetEnabled: Bool = SemanticWorkBudget.defaultEnabled,
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
         requiresReaderLifecycle: Bool = false, requiresModelLifecycle: Bool = false, deferInitialStart: Bool = false, remote: Bool = false,
         watcherDelivery: SemanticWatcherDelivery = SemanticWatcherDelivery(),
         eventHistory: @escaping @Sendable ([String]) -> (UInt64, String?) = {
             (AskFSEventsWatcher.currentEventID, AskFSEventsWatcher.historySignature(paths: $0))
         },
         progressDelivery: SemanticIndexProgressDelivery = SemanticIndexProgressDelivery(),
         downloadProgress: SemanticDownloadProgressDelivery = SemanticDownloadProgressDelivery(),
         countSnapshot: @escaping @Sendable (SemanticFileStore) throws -> SemanticFileStore.Counts = { try $0.counts() }) {
        self.remote = remote
        self.watcherDelivery = watcherDelivery; self.eventHistory = eventHistory
        self.progressDelivery = progressDelivery; self.countSnapshot = countSnapshot
        self.downloadProgress = downloadProgress
        self.settings = settings; self.directory = directory; self.helper = helper
        self.supported = supported; self.watcher = watcher; self.access = access
        self.budgetEnabled = budgetEnabled
        self.lowPowerMode = lowPowerMode; self.thermalConstrained = thermalConstrained
        self.mediaModels = mediaModels; self.idle = idle; self.makeMediaEncoder = makeMediaEncoder
        self.models = models; self.readers = SemanticFileReaders(makeReader: makeReader, requiresLifecycle: requiresReaderLifecycle)
        self.makeEncoder = makeEncoder; self.makeQuery = makeQuery; self.embeddingOwners = embeddingOwners ?? SemanticEmbeddingOwners(requiresLifecycle: requiresModelLifecycle)
        self.preferences = settings.semanticFileSearch
        guard automaticStart, !remote else { return }
        let authority = settingsAuthority, defaults = settings.defaults
        observers.append(NotificationCenter.default.publisher(for: SemanticSettingsChange.notification)
            .sink { notification in
                guard let source = notification.object as? SettingsStore, source.defaults === defaults,
                      let change = notification.userInfo?["change"] as? SemanticSettingsChange else { return }
                authority.receive(change)
            })
        self.observers
            .append(NotificationCenter.default.publisher(for: .askLauncherSearchSettingsDidChange)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.start() }
                })
        observers
            .append(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).sink { [weak self] _ in
                Task { @MainActor in self?.refreshPause() }
            })
        observers
            .append(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refreshPause() }
                })
        if !deferInitialStart { self.start() }
    }

    /// Checks ownership at actor boundaries; this cannot undo work already entered
    /// off actor, or substitute for filesystem/source validation inside a worker.
    private func ownsLifecycle(_ lifecycle: AskSearchCancellation, fingerprint: String) -> Bool {
        token === lifecycle && !lifecycle.isCancelled && !removing &&
            self.fingerprint == fingerprint && settingsFingerprint == fingerprint
    }

    private var backgroundPaused: Bool {
        busy || manuallyPaused || lowPowerMode() || thermalConstrained()
    }

    private func currentPermissionRecovery() -> AskSearchCancellation {
        if busy || thermalConstrained() { permissionRecoveryEpoch.cancel() }
        else if permissionRecoveryEpoch.isCancelled { permissionRecoveryEpoch = AskSearchCancellation() }
        return permissionRecoveryEpoch
    }

    func setForegroundBusy(_ busy: Bool) {
        if remote { remoteSend("busy." + FeatureProcess.role.rawValue, value: FeatureForegroundActivity(busy: busy)); return }
        guard self.busy != busy else { return }
        self.busy = busy
        if busy {
            permissionRecoveryEpoch.cancel()
            warmup?.cancel(); warmup = nil; queryWorker?.stop()
            queryState = .idle
        }
        refreshPause()
    }

    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        if remote {
            guard !enabled || (supported && settings.askQuickFileSearchEnabled) else { return false }
            var next = settings.semanticFileSearch; next.enabled = enabled; settings.semanticFileSearch = next
            remoteSend("enabled", value: enabled); return true
        }
        guard !enabled || (supported && settings.askQuickFileSearchEnabled) else { return false }
        var next = settings.semanticFileSearch
        next.enabled = enabled
        if enabled,
           SemanticFilePolicy.scope(names: settings.askLauncherSearchSettings, fullDiskAccess: true).roots
           .isEmpty {
            return false
        }
        settings.semanticFileSearch = next
        start(force: true)
        return true
    }

    func pause(_ paused: Bool) {
        if remote { remoteSend("pause", value: paused); return }
        manuallyPaused = paused; refreshPause()
    }

    private func refreshPause() {
        let paused = self.backgroundPaused
        // Foreground/thermal pressure can always stop old work; only its original
        // current scope may resume it or publish a phase transition.
        if paused { pauseGate.setPaused(true) }
        guard let fingerprint, ownsLifecycle(token, fingerprint: fingerprint) else { return }
        self.pauseGate.setPaused(paused)
        if paused {
            if phase == .indexing {
                pausedIndexing = true; phase = .paused
            } else if phase == .ready {
                pausedReady = true; phase = .paused
            }
            return
        }
        guard phase == .paused else { return }
        if pausedIndexing {
            pausedIndexing = false; phase = .indexing
        } else if pausedReady {
            pausedReady = false; phase = .ready; scheduleReconcile()
        } else {
            self.start(force: true, renewReaderAuthorization: false)
        }
    }

    /// Called once by application startup, never by a health factory or recovery.
    func startForApplication(using registry: ModuleRegistry, startModules: Bool = true) async {
        guard !stopped else { return }
        if remote { remoteSend("start", value: false); return }
        if startModules { _ = await registry.startAll() }
        guard !Task.isCancelled else { return }
        start(force: true)
    }

    // Keep generation checks beside every suspension in this lifecycle transition.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func start(force: Bool = false) {
        if remote { remoteSend("start", value: force); return }
        start(force: force, renewReaderAuthorization: true)
    }

    func rescanAll() {
        if remote { remoteSend("rescan", value: false); return }
        nextReason = .rebuild; start(force: true, renewReaderAuthorization: true, fullScan: true) }

    private func start(force: Bool, renewReaderAuthorization: Bool, fullScan: Bool = false) {
        guard !removing, !stopped else { return }
        preferences = settings.semanticFileSearch
        let names = settings.askLauncherSearchSettings
        let key = "\(preferences.enabled)\u{3}\(names.fileIndexFingerprint)\u{3}\(settings.askQuickFileSearchEnabled)"
        guard force || fingerprint != key || token.isCancelled else { return }
        if renewReaderAuthorization {
            readerAuthorization = readers.authorization()
            embeddingAuthorization = embeddingOwners.authorization()
        }
        pendingChanges = .init(); pendingProcessingRetry = false
        pausedIndexing = false; pausedReady = false
        pauseGate.setPaused(backgroundPaused)
        if fingerprint != key || !backgroundPaused {
            indexProgress = nil
        }
        currentProcessingPath = nil
        fingerprint = key
        invalidateIndexProgress()
        watcherDelivery.invalidate()
        cancelDownload()
        let previousDownload = download
        token.cancel(); token = AskSearchCancellation()
        settingsAuthority.bind(token, fingerprint: key)
        let documentSource = SemanticIndexPauseGate.Source(lifecycle: token)
        self.documentSource = documentSource; pauseGate.begin(documentSource)
        readers.stop(); embeddingOwners.stop()
        let token = token
        let previous = work
        work?.cancel(); rescan?.cancel(); watcher.stop()
        let previousJournal = eventJournal
        eventJournal = nil
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil; queryState = .idle
        scope = nil; store = nil; queryValidator = nil
        guard supported, preferences.enabled,
              settings.askQuickFileSearchEnabled else { phase = .off; return }
        self.mediaDownload = nil; self.mediaFailed = false
        self.phase = .preparing
        let directory = directory, model = self.modelURL, helper = helper, access = access
        let preparationBudget = preparationBudget
        let models = models
        work = Task { [weak self] in
            await previous?.value
            await previousDownload?.value
            await Task.detached(priority: .utility) { previousJournal?.close() }.value
            guard !Task.isCancelled, self?.ownsLifecycle(token, fingerprint: key) == true else { return }
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    guard !token.isCancelled else { throw CancellationError() }
                    let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: access())
                    guard !token.isCancelled else { throw CancellationError() }
                    return try preparationBudget.perform(cancelled: { token.isCancelled }) {
                        let database = Result {
                            try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"),
                                                  cancelled: { token.isCancelled })
                        }
                        guard !token.isCancelled else { throw CancellationError() }
                        let events = try SemanticIndexEvents(url: directory.appendingPathComponent("index-events.sqlite"))
                        return (scope, database, events)
                    }
                }.value
                guard let self, !Task.isCancelled, self.ownsLifecycle(token, fingerprint: key) else { return }
                scope = prepared.0; blocked = prepared.0.blockedInScope
                store = try? prepared.1.get(); eventJournal = prepared.2
                queryValidator = SemanticFileValidator(reader: readers.validation.scope(generation: readerAuthorization?.validation))
                if let database = store {
                    await updateCounts(database, lifecycle: token)
                }
                guard !Task.isCancelled, ownsLifecycle(token, fingerprint: key) else { return }
                guard FileManager.default.fileExists(atPath: model.path) else {
                    self.modelReady = false; self.phase = .modelRequired; return
                }
                try await Task.detached(priority: .utility) {
                    try preparationBudget.perform(cancelled: { token.isCancelled }, operation: {
                        try models.verify(model, cancelled: { token.isCancelled })
                    })
                }.value
                guard !Task.isCancelled, ownsLifecycle(token, fingerprint: key) else { return }
                modelReady = true
                let database = try prepared.1.get()
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { phase = .failed; return }
                queryWorker = makeQuery?(helper, model) ?? SemanticEmbeddingWorker(
                    helper: helper, model: model, ownership: embeddingOwners.query, authorization: embeddingAuthorization?.query ?? .init(generation: nil), lifecycle: token)
                if prewarmRequested { prepareForSearch() }
                if fullScan { try database.invalidateDiscovery() }
                let (latestEventID, signature) = eventHistory(prepared.0.roots)
                self.volumeSignature = signature
                let previousEventID: UInt64?
                if let signature {
                    previousEventID = try database.completedEventID(scope: prepared.0, volumeSignature: signature)
                } else {
                    previousEventID = nil
                }
                let savedEventID = previousEventID.flatMap { $0 <= latestEventID ? $0 : nil }
                let watchEventID = try prepared.2.resume(scope: prepared.0, volumeSignature: signature,
                                                        after: savedEventID, latest: latestEventID)
                self.committedEventID = savedEventID ?? watchEventID
                self.pendingEventID = watchEventID
                let prunePending = try savedEventID != nil && database.hasPendingPrune()
                let retryDirectories = savedEventID != nil ? try database.failedDirectories() : []
                let source = SemanticWatcherDelivery.Source(scope: prepared.0,
                    indexDirectory: directory.path, lifecycle: token)
                let delivery = watcherDelivery
                delivery.begin(source) { [weak self] snapshot in
                    self?.receiveChanges(snapshot, lifecycle: token, fingerprint: key)
                }
                let events = prepared.2, eventScope = prepared.0
                watcher.start(paths: eventScope.roots, since: watchEventID) { [weak self] changes, last in
                    guard !token.isCancelled else { return }
                    do {
                        let changed = try events.append(changes, scope: eventScope, directory: directory.path,
                                                        eventID: last, cancelled: { token.isCancelled })
                        guard !token.isCancelled else { return }
                        // Ignored writes (including our own WAL files) only advance the
                        // in-memory receipt. They must not wake another index transaction.
                        guard changed || changes.isEmpty else { return }
                        delivery.offer(changes, eventID: last, from: source)
                    } catch {
                        Task { @MainActor in
                            guard let self, self.ownsLifecycle(token, fingerprint: key) else { return }
                            token.cancel(); self.work?.cancel(); self.watcher.stop(); self.phase = .failed
                        }
                    }
                }
                if self.backgroundPaused {
                    guard !Task.isCancelled, ownsLifecycle(token, fingerprint: key) else { return }
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
                guard let self, !Task.isCancelled, self.ownsLifecycle(token, fingerprint: key) else { return }
                if case SemanticMediaFailure.unavailable = error { self.mediaFailed = true }
                if case SemanticFileStore.Failure.invalidVector = error {
                    self.modelReady = false
                }
                phase = .failed
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
                return try (countSnapshot(database), database.hasPublishedContent())
            }.value
        } onCancel: { cancellation.cancel() }
        if let (counts, content) = counts {
            guard !Task.isCancelled, !lifecycle.isCancelled, !removing, store === database,
                  fingerprint == settingsFingerprint,
                  attempt == nil || indexAttempt === attempt else { return }
            hasPublishedContent = content
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
        indexProgress = summary; diagnostics = summary.diagnostics
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
        let id = UUID(), snapshot = countSnapshot
        countRefreshID = id
        countRefresh = Task { [weak self] in
            let cancellation = AskSearchCancellation()
            let result = await withTaskCancellationHandler {
                try? await Task.detached(priority: .utility) {
                    guard !request.lifecycle.isCancelled, !cancellation.isCancelled else { throw CancellationError() }
                    return try (snapshot(request.database), request.database.hasPublishedContent())
                }.value
            } onCancel: { cancellation.cancel() }
            guard let self, countRefreshID == id else { return }
            if let (counts, content) = result, !Task.isCancelled, !request.lifecycle.isCancelled,
               !removing, store === request.database, indexAttempt === request.attempt,
               fingerprint == settingsFingerprint {
                hasPublishedContent = content; files = counts.files; chunks = counts.chunks; indexedCounts = counts
            }
            countRefresh = nil; countRefreshID = nil
            let next = pendingCountRefresh
            pendingCountRefresh = nil
            if let next, !next.lifecycle.isCancelled, indexAttempt === next.attempt {
                startCountRefresh(next)
            }
        }
    }

    private func receiveChanges(_ snapshot: SemanticWatcherDelivery.Snapshot,
                                lifecycle: AskSearchCancellation, fingerprint: String) {
        guard ownsLifecycle(lifecycle, fingerprint: fingerprint) else { return }
        pendingEventID = max(pendingEventID, snapshot.eventID)
        let plan = snapshot.plan
        pendingChanges.mergeForHandoff(plan)
        guard plan.fullScan || !plan.files.isEmpty || !plan.directories.isEmpty ||
            pendingEventID > committedEventID else { return }
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard let fingerprint, ownsLifecycle(token, fingerprint: fingerprint) else { return }
        let lifecycle = token
        guard self.phase != .indexing, !self.backgroundPaused,
              pendingProcessingRetry || pendingChanges.fullScan || !pendingChanges.files.isEmpty ||
              !pendingChanges.directories.isEmpty ||
              self.pendingEventID > self.committedEventID else { return }
        self.rescan?.cancel()
        self.rescan = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.reconcilePending(lifecycle: lifecycle, fingerprint: fingerprint)
        }
    }

    private func reconcilePending(lifecycle: AskSearchCancellation, fingerprint: String) {
        guard ownsLifecycle(lifecycle, fingerprint: fingerprint), !self.backgroundPaused, self.phase == .ready || self.phase == .failed,
              readerAuthorization?.allowsIndexing(in: readers) == true,
              let database = self.store, let scope = self.scope else { return }
        // The journal is authoritative, including overflow subtree requests. The bounded
        // handoff plan is only a wake signal and must not schedule a second full scan.
        let paths: [String] = []
        let directories: [String] = []
        let eventID = self.pendingEventID
        if paths.isEmpty && directories.isEmpty && eventJournal == nil && !pendingProcessingRetry {
            do {
                try database.saveEventID(eventID, scope: scope, volumeSignature: volumeSignature)
                self.committedEventID = eventID
            } catch { self.phase = .failed }
            return
        }
        pendingChanges = .init(); pendingProcessingRetry = false
        self.indexProgress = nil
        self.phase = .indexing
        nextReason = .filesystem
        self.beginIndexing(database, scope: scope, token: token, paths: paths,
                           directories: directories, processedEventID: eventID)
    }

    deinit { pauseGate.invalidate(); watcherDelivery.invalidate(); downloadProgress.invalidate(); progressDelivery.invalidate(); countRefresh?.cancel(); token.cancel(); readers.stop(); embeddingOwners.stop(); work?.cancel(); download?.cancel(); rescan?.cancel(); warmup?.cancel() }
}

extension SemanticFileSearchService {
    /// One joined sampler keeps long media inference visible without accumulating UI tasks.
    private func monitorDiagnostics(_ database: SemanticFileStore, token: AskSearchCancellation,
                                    budget: SemanticWorkBudget,
                                    since start: SemanticWorkBudget.Statistics) -> Task<Void, Never> {
        Task { [weak self] in
            while !token.isCancelled, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !token.isCancelled, !Task.isCancelled else { return }
                let snapshot = budget.statistics
                let value = try? await Task.detached(priority: .utility) {
                    guard !token.isCancelled else { throw CancellationError() }
                    try database.updateBudget(snapshot, since: start)
                    return try database.runDiagnostics()
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled, store === database else { return }
                if diagnostics != value {
                    diagnostics = value
                }
            }
        }
    }

    // Do not retain the service while media waits for user idle time.
    // Keep resource ownership, cancellation and state checks in one operation.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func beginIndexing(_ database: SemanticFileStore, scope: AskFileScope, token: AskSearchCancellation,
                               paths: [String]? = nil, directories: [String] = [],
                               scanStartEventID: UInt64? = nil, prunePending: Bool = false,
                               processedEventID: UInt64? = nil) {
        let fingerprint = settingsFingerprint
        guard ownsLifecycle(token, fingerprint: fingerprint), let documentSource else { return }
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
        let events = eventJournal, budget = budget, reason = nextReason
        let configuration = fingerprint
        nextReason = .resume
        let budgetStart = budget.statistics
        let documents: () throws -> SemanticIndexPauseGate.DocumentWork = {
            guard !token.isCancelled else { throw CancellationError() }
            try events?.transfer(to: database, cancelled: { token.isCancelled })
            guard !token.isCancelled else { throw CancellationError() }
            return pauseGate.takeDocuments(from: documentSource)
        }
        invalidateIndexProgress()
        let delivery = progressDelivery, attempt = SemanticIndexProgressDelivery.Source()
        indexAttempt = attempt
        delivery.begin(attempt) { [weak self] snapshot in
            self?.receiveIndexProgress(snapshot, database: database, lifecycle: token, attempt: attempt)
        }
        let reportDownload: @Sendable (Double?) -> Void = { delivery.offer(.download($0), from: attempt) }
        let reportProgress: @Sendable (SemanticFileIndexer.Summary) -> Void = { summary in
            guard !token.isCancelled else { return }
            try? database.updateBudget(budget.statistics, since: budgetStart)
            var summary = summary
            summary.diagnostics = try? database.runDiagnostics()
            delivery.offer(.summary(summary), from: attempt)
        }
        let reportCurrent: @Sendable (String?) -> Void = { delivery.offer(.path($0), from: attempt) }
        self.work = Task { [weak self] in
            let monitor = self?.monitorDiagnostics(database, token: token, budget: budget, since: budgetStart)
            defer { monitor?.cancel() }
            do {
                let result = try await Task.detached(priority: .utility) {
                    defer { reader.stop(); priorityReader.stop() }
                    guard !token.isCancelled else { throw CancellationError() }
                    return try budget.perform(cancelled: { token.isCancelled }) {
                    var completed = false
                    defer {
                        try? database.updateBudget(budget.statistics, since: budgetStart)
                        try? database.finishRun(stage: completed ? .complete : (token.isCancelled ? .cancelled : .failed))
                    }
                    let encoder = makeEncoder?(helper, model) ?? SemanticEmbeddingWorker(
                        helper: helper, model: model, indexing: true, ownership: embeddingOwners.indexing, authorization: embeddingAuthorization?.indexing ?? .init(generation: nil), lifecycle: token)
                    defer { encoder.release() }
                    // A factory can suspend while settings synchronously revoke this scope.
                    guard !token.isCancelled else { throw CancellationError() }
                    try database.beginRun(reason: reason, configuration: configuration)
                    let media = SemanticMediaWorker(helper: helper, model: model, projector: projector,
                        models: mediaModels, makeEncoder: makeMediaEncoder, progress: reportDownload,
                        embeddingOwners: embeddingOwners, authorization: embeddingAuthorization?.media ?? .init(generation: nil))
                    let result: SemanticFileIndexer.Summary
                    if let paths {
                        result = try SemanticFileIndexer.reconcile(
                            paths: paths, scope: scope, store: database, reader: reader,
                            encoder: encoder, media: media, idle: { idle() && !pauseGate.isPaused },
                            paused: { pauseGate.isPaused }, documents: documents,
                            priorityReader: priorityReader,
                            cancelled: { token.isCancelled }, progress: reportProgress,
                            directories: directories, prunePending: prunePending, current: reportCurrent
                        )
                    } else {
                    result = try SemanticFileIndexer.run(scope: scope, store: database, reader: reader,
                                                       encoder: encoder, media: media,
                                                       idle: { idle() && !pauseGate.isPaused },
                                                       paused: { pauseGate.isPaused },
                                                       documents: documents,
                                                       priorityReader: priorityReader,
                                                       cancelled: { token.isCancelled }, progress: reportProgress,
                                                       discovered: {
                                                           guard !token.isCancelled else { throw CancellationError() }
                                                           if let scanStartEventID {
                                                               try database.saveEventID(scanStartEventID, scope: scope,
                                                                                        volumeSignature: volumeSignature)
                                                           }
                                                       },
                                                       current: reportCurrent)
                    }
                    completed = true
                    return result
                    }
                }.value
                monitor?.cancel(); await monitor?.value
                guard let self, !Task.isCancelled, ownsLifecycle(token, fingerprint: fingerprint), indexAttempt === attempt else { return }
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
                    guard !Task.isCancelled, ownsLifecycle(token, fingerprint: fingerprint), indexAttempt === attempt else { return }
                }
                guard !Task.isCancelled, ownsLifecycle(token, fingerprint: fingerprint), indexAttempt === attempt else { return }
                await self.updateCounts(database, lifecycle: token, attempt: attempt)
                guard !Task.isCancelled, ownsLifecycle(token, fingerprint: fingerprint), indexAttempt === attempt else { return }
                self.mediaDownload = nil
                self.indexProgress = nil
                self.currentProcessingPath = nil
                if self.backgroundPaused {
                    self.pausedIndexing = false
                    self.pausedReady = true
                    self.phase = .paused
                } else {
                    phase = .ready
                }
                scheduleReconcile()
            } catch {
                monitor?.cancel(); await monitor?.value
                guard let self, !Task.isCancelled, ownsLifecycle(token, fingerprint: fingerprint), indexAttempt === attempt else { return }
                self.pendingChanges.mergeForHandoff(.init(files: Set(paths ?? []), directories: Set(directories)))
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
        if remote { remoteSend("download", value: false); return }
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
            defer {
                if self?.downloadAttempt === attempt {
                    progress.invalidate()
                    self?.downloadAttempt = nil; self?.download = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard self?.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) == true else { throw CancellationError() }
                let (temporary, response) = try await models.fetch { received in
                    progress.offer(min(1, max(0, Double(received) / Double(SemanticModel.bytes))), from: attempt)
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard self?.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) == true else { throw CancellationError() }
                guard let http = response as? HTTPURLResponse,
                      (http.statusCode == 200 || http.statusCode == 206) else { throw URLError(.badServerResponse) }
                let cancellation = AskSearchCancellation()
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        guard !cancellation.isCancelled, !lifecycle.isCancelled else { throw CancellationError() }
                        installAttempted.cancel()
                        try models.install(temporary, to: target, cancelled: { cancellation.isCancelled || lifecycle.isCancelled })
                    }.value
                } onCancel: { cancellation.cancel() }
                try Task.checkCancellation()
                guard self?.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) == true else { throw CancellationError() }
                guard let self else { return }
                progress.invalidate()
                mutation.finish()
                self.downloadAttempt = nil; self.download = nil; self.modelReady = true
                self.start(force: true, renewReaderAuthorization: false)
            } catch {
                // A replacement start owns its own preparation/terminal phase. The
                // old attempt may retire its slot, never publish into that lifecycle.
                guard let self, self.ownsDownload(attempt, lifecycle: lifecycle, fingerprint: fingerprint) else { return }
                progress.invalidate()
                self.phase = Task.isCancelled && !installAttempted.isCancelled ? .modelRequired : .failed
            }
        }
    }

    private func reportModelDownload(_ received: Int64) {
        guard download != nil, preferences.enabled else { return }
        phase = .downloading(min(1, Double(received) / Double(SemanticModel.bytes)))
    }

    func cancelDownload() {
        if remote { remoteSend("cancelDownload", value: false); return }
        downloadProgress.invalidate()
        download?.cancel()
    }

    func prepareModelIfNeeded() async {
        if remote { _ = await remoteRequest("prepare", value: false) as FeatureRPC.Empty?; return }
        let lifecycle = token, fingerprint = settingsFingerprint
        await self.work?.value
        guard !Task.isCancelled, !lifecycle.isCancelled, fingerprint == settingsFingerprint else { return }
        if self.phase == .modelRequired {
            self.downloadModel()
        }
    }

    /// Retire producers before their readers and models. Stopping only the
    /// readers cannot release a callback waiting for media idle time or a pause.
    /// Preserve settings and persisted indexes for the next application launch.
    func shutdown() async {
        guard !remote else { return }
        stopped = true
        observers.removeAll()
        token.cancel(); permissionRecoveryEpoch.cancel()
        invalidateIndexProgress(); watcherDelivery.invalidate(); downloadProgress.invalidate()
        pauseGate.invalidate(); documentSource = nil; pendingChanges = .init()
        watcher.stop()
        let pending = [work, download, rescan, warmup, countRefresh].compactMap { $0 }
        pending.forEach { $0.cancel() }
        readers.stop(); embeddingOwners.stop()
        queryWorker?.stop(); queryWorker = nil
        for task in pending { await task.value }
        work = nil; download = nil; rescan = nil; warmup = nil; countRefresh = nil
        let journal = eventJournal
        eventJournal = nil
        await Task.detached(priority: .utility) { journal?.close() }.value
        queryState = .idle; phase = .off
        currentProcessingPath = nil; resourceWaitReason = nil
    }

    /// Stop every writer before removing artifacts. The name index is never touched.
    func clear(removeModel: Bool = false) async {
        if remote { _ = await remoteRequest("clear", value: removeModel) as FeatureRPC.Empty?; return }
        guard !removing else { return }
        removing = true
        let pendingCounts = countRefresh
        pendingCounts?.cancel()
        _ = setEnabled(false)
        preferences = settings.semanticFileSearch
        invalidateIndexProgress()
        watcherDelivery.invalidate()
        pauseGate.invalidate(); documentSource = nil; pendingChanges = .init()
        token.cancel(); work?.cancel(); rescan?.cancel(); cancelDownload(); watcher.stop()
        readers.stop(); embeddingOwners.stop()
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil
        await work?.value; await download?.value; await countRefresh?.value
        let database = store, directory = directory, model = modelURL, projector = mediaModelURL
        let embeddingOwners = embeddingOwners, events = eventJournal
        eventJournal = nil
        do {
            // Revoked native workers retain model ownership through host work and
            // actual collection. A timeout preserves files for an explicit retry.
            try await embeddingOwners.waitUntilIdle()
            try await Task.detached(priority: .utility) {
                let mutation = try embeddingOwners.mutation(.model)
                defer { mutation.finish() }
                events?.close()
                if let database {
                    try database.destroy()
                } else {
                    try SemanticFileStore.removeFiles(at: directory.appendingPathComponent("semantic-files.sqlite"))
                }
                try SemanticFileStore.removeFiles(at: directory.appendingPathComponent("index-events.sqlite"))
                let scratch = directory.appendingPathComponent(".typeflux-media-cache")
                if FileManager.default
                    .fileExists(atPath: scratch.path) {
                    try FileManager.default.removeItem(at: scratch)
                }
                if removeModel {
                    for artifact in [model, projector] where FileManager.default.fileExists(atPath: artifact.path) {
                        try FileManager.default.removeItem(at: artifact)
                    }
                }
            }.value
            files = 0; chunks = 0; hasPublishedContent = false; indexedCounts = .init()
            skipped = 0; mediaDownload = nil; mediaFailed = false
            indexProgress = nil; phase = .off
            currentProcessingPath = nil
            if removeModel {
                modelReady = false
            }
        } catch { phase = .failed }
        store = nil; scope = nil; queryValidator = nil; fingerprint = nil; removing = false
    }

    /// Bytes on disk for the content index (database and journal) and the model weights.
    func storage() -> (index: Int64, model: Int64) {
        func size(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let database = directory.appendingPathComponent("semantic-files.sqlite")
        let index = ["", "-wal", "-shm"].reduce(Int64(0)) {
            $0 + size(URL(fileURLWithPath: database.path + $1))
        }
        let events = directory.appendingPathComponent("index-events.sqlite")
        let eventBytes = ["", "-wal", "-shm"].reduce(Int64(0)) {
            $0 + size(URL(fileURLWithPath: events.path + $1))
        }
        return (index + eventBytes, size(modelURL) + size(mediaModelURL))
    }

    func rebuild() async {
        if remote { _ = await remoteRequest("rebuild", value: false) as FeatureRPC.Empty?; return }
        let scope = settings.askLauncherSearchSettings.fileIndexFingerprint
        await clear()
        // Scope edits during clearing win; never restore an outdated filename-search scope.
        guard phase == .off, settings.askLauncherSearchSettings.fileIndexFingerprint == scope else { return }
        _ = setEnabled(true)
        nextReason = .rebuild
    }

    func processingPage(_ section: SemanticFileStore.ProcessingSection, offset: Int,
                        limit: Int = 50) async -> SemanticFileStore.ProcessingPage? {
        if remote { return await remoteRequest("page", value: FeatureProcessingPage(section: section, offset: offset, limit: limit)) }
        guard let database = store, let fingerprint,
              ownsLifecycle(token, fingerprint: fingerprint) else { return nil }
        let lifecycle = token
        let page = try? await Task.detached(priority: .utility) {
            try database.processingPage(section, offset: offset, limit: limit)
        }.value
        guard store === database, ownsLifecycle(lifecycle, fingerprint: fingerprint) else { return nil }
        return page
    }

    func canRetryProcessingItem(_ item: SemanticFileStore.ProcessingItem) -> Bool {
        if remote { return item.canRetry && isEnabled && modelReady }
        guard item.canRetry, supported, preferences.enabled, settings.semanticFileSearch.enabled,
              settings.askQuickFileSearchEnabled, modelReady, let fingerprint,
              ownsLifecycle(token, fingerprint: fingerprint),
              readerAuthorization?.allowsIndexing(in: readers) == true else { return false }
        let current = SemanticFilePolicy.scope(names: settings.askLauncherSearchSettings, fullDiskAccess: access())
        return current.includes(item.path, isDirectory: false) && SemanticFilePolicy.allows(item.path)
    }

    /// Queue one selection without restarting discovery or resetting unrelated generations.
    func retryProcessingItem(_ item: SemanticFileStore.ProcessingItem) async -> Bool {
        if remote { return await remoteRequest("retry", value: item) ?? false }
        guard !Task.isCancelled, canRetryProcessingItem(item), let database = store,
              let fingerprint else { return false }
        let lifecycle = token
        let request = AskSearchCancellation()
        let queued = await withTaskCancellationHandler {
            (try? await Task.detached(priority: .utility) {
                try database.retryProcessingItem(item, cancelled: { lifecycle.isCancelled || request.isCancelled })
            }.value) == true
        } onCancel: { request.cancel() }
        guard queued, !Task.isCancelled, store === database,
              ownsLifecycle(lifecycle, fingerprint: fingerprint), canRetryProcessingItem(item) else { return false }
        if item.priority == .document, let documentSource {
            pauseGate.enqueueDocuments([item.path], from: documentSource)
        }
        if !backgroundPaused, phase == .ready || phase == .failed, let scope {
            indexProgress = nil; phase = .indexing; nextReason = .resume
            pendingProcessingRetry = false
            beginIndexing(database, scope: scope, token: lifecycle, paths: [])
        } else {
            // Retain a wake intent if the current drain already observed an empty queue.
            pendingProcessingRetry = true
        }
        return true
    }
}

extension SemanticFileSearchService {
    func endSearch() {
        if remote { remoteSend("endSearch", value: false); return }
        prewarmRequested = false
        warmup?.cancel(); warmup = nil
        if queryState == .warming {
            queryState = .idle
        }
    }

    func prepareForSearch() {
        if remote { remoteSend("prepareSearch", value: false); return }
        prewarmRequested = true
        guard isEnabled, !busy, !thermalConstrained(), warmup == nil, let queryValidator, let scope else { return }
        let queryWorker = modelReady ? queryWorker : nil
        let lifecycle = token, preparation = AskSearchCancellation(), gate = pauseGate, store = modelReady ? store : nil
        gate.beginQuery(lifecycle: lifecycle)
        queryState = .warming
        warmup = Task { [weak self] in
            defer { gate.endQuery(lifecycle: lifecycle) }
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
        if remote {
            let result: [AskFileHit] = await remoteRequest("search", value: FeatureSemanticQuery(text: text, type: type, limit: min(100, max(0, limit)))) ?? []
            guard !Task.isCancelled else { return [] }
            progress(result)
            return result
        }
        guard limit > 0, isEnabled, let query = SemanticFilePolicy.query(text, type: type),
              let store, let scope, let queryValidator else { return [] }
        let lifecycle = token, cancellation = AskSearchCancellation()
        let recoveryEpoch = currentPermissionRecovery()
        let access = access
        let trace = SemanticSearchTrace.current ?? .init()
        queryGeneration += 1
        let generation = queryGeneration
        // Lexical lookup and current-permission validation also own foreground priority.
        pauseGate.beginQuery(lifecycle: lifecycle)
        defer {
            pauseGate.endQuery(lifecycle: lifecycle)
            if generation == queryGeneration, queryState == .searching {
                queryState = .idle
            }
        }
        let permissionBudgetExpired = AskSearchCancellation()
        let permissionRecoveryStarted = AskSearchCancellation()
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
                        var valid = queryValidator.validateBatch(hits, scope: currentScope, limit: min(100, limit),
                                                                 cancelled: cancelled)
                        // A pure semantic result gets one startup-budget recovery with fresh
                        // permissions. An exhausted FTS budget still returns immediately.
                        if vector != nil, valid.hits.isEmpty, valid.canRecover, !recoveryEpoch.isCancelled,
                           !permissionRecoveryStarted.isCancelled,
                           !cancelled() {
                            permissionRecoveryStarted.cancel()
                            trace.mark("metadata-recovery")
                            valid = queryValidator.validateBatch(hits, scope: currentScope, limit: min(100, limit),
                                                                 recovering: true,
                                                                 cancelled: { cancelled() || recoveryEpoch.isCancelled
                                                                 })
                        }
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


extension SemanticFileSearchService {
    func remoteSend<Value: Encodable & Sendable>(_ action: String, value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        FeatureProcess.send(.init(destination: .background, action: "semantic." + action, payload: data))
    }

    private func remoteRequest<Value: Encodable & Sendable, Result: Decodable & Sendable>(_ action: String, value: Value) async -> Result? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? await FeatureBackgroundCall.request(.init(destination: .background, action: "semantic." + action, payload: data))
    }

    func backgroundSnapshot() -> FeatureSemanticSnapshot {
        .init(phase: phase, files: files, chunks: chunks, hasPublishedContent: hasPublishedContent, indexedCounts: indexedCounts, skipped: skipped, mediaDownload: mediaDownload, mediaFailed: mediaFailed, resourceWaitReason: resourceWaitReason, diagnostics: diagnostics, indexProgress: indexProgress, currentProcessingPath: currentProcessingPath, blocked: blocked, modelReady: modelReady, preferences: preferences, queryState: queryState, manuallyPaused: manuallyPaused, enabled: isEnabled)
    }

    func applyRemoteSnapshot(_ snapshot: FeatureSemanticSnapshot) {
        guard remote else { return }
        remoteEnabled = snapshot.enabled
        if phase != snapshot.phase { phase = snapshot.phase }
        if files != snapshot.files { files = snapshot.files }
        if chunks != snapshot.chunks { chunks = snapshot.chunks }
        if hasPublishedContent != snapshot.hasPublishedContent { hasPublishedContent = snapshot.hasPublishedContent }
        if indexedCounts != snapshot.indexedCounts { indexedCounts = snapshot.indexedCounts }
        if skipped != snapshot.skipped { skipped = snapshot.skipped }
        if mediaDownload != snapshot.mediaDownload { mediaDownload = snapshot.mediaDownload }
        if mediaFailed != snapshot.mediaFailed { mediaFailed = snapshot.mediaFailed }
        if resourceWaitReason != snapshot.resourceWaitReason { resourceWaitReason = snapshot.resourceWaitReason }
        if diagnostics != snapshot.diagnostics { diagnostics = snapshot.diagnostics }
        if indexProgress != snapshot.indexProgress { indexProgress = snapshot.indexProgress }
        if currentProcessingPath != snapshot.currentProcessingPath { currentProcessingPath = snapshot.currentProcessingPath }
        if blocked != snapshot.blocked { blocked = snapshot.blocked }
        if modelReady != snapshot.modelReady { modelReady = snapshot.modelReady }
        if preferences != snapshot.preferences { preferences = snapshot.preferences }
        if queryState != snapshot.queryState { queryState = snapshot.queryState }
        if manuallyPaused != snapshot.manuallyPaused { manuallyPaused = snapshot.manuallyPaused }
    }
}
