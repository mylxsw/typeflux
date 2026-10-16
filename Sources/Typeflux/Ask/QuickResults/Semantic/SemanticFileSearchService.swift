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
        automaticStart: !AskFileIndex.isTesting
    )
    enum Phase: Equatable { case off, preparing, modelRequired, downloading(Double), indexing, ready, paused, failed }
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
    enum QueryState: Equatable { case idle, warming, searching, degraded }
    @Published private(set) var queryState: QueryState = .idle
    var isEnabled: Bool {
        supported && preferences.enabled && settings.semanticFileSearch.enabled && settings.askQuickFileSearchEnabled
            && store != nil && scope != nil && (modelReady || hasPublishedContent) && !removing && fingerprint ==
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
    private var countRefreshID: UUID?
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
    private var pausedIndexing = false
    private var pausedReady = false
    private var nextReason: SemanticIndexDiagnostics.Reason = .startup
    private var eventJournal: SemanticIndexEvents?
    private var removing = false
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
         idle: @escaping @Sendable () -> Bool = { true },
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
        self.budgetEnabled = budgetEnabled
        self.lowPowerMode = lowPowerMode; self.thermalConstrained = thermalConstrained
        self.mediaModels = mediaModels; self.idle = idle; self.makeMediaEncoder = makeMediaEncoder
        self.models = models; self.makeReader = makeReader; self.makeEncoder = makeEncoder; self.makeQuery = makeQuery
        preferences = settings.semanticFileSearch
        guard automaticStart else { return }
        observers
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
        start()
    }

    private var backgroundPaused: Bool {
        busy || manuallyPaused || thermalConstrained()
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
        manuallyPaused = paused; refreshPause()
    }

    private func refreshPause() {
        let paused = backgroundPaused
        pauseGate.setPaused(paused)
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
            guard let store, let scope else { start(force: true); return }
            phase = .indexing
            beginIndexing(store, scope: scope, token: token)
        }
    }

    func start(force: Bool = false) {
        start(force: force, reason: nil)
    }

    // Keep generation checks beside every suspension in this lifecycle transition.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func start(force: Bool, reason: SemanticIndexDiagnostics.Reason?) {
        guard !removing else { return }
        preferences = settings.semanticFileSearch
        let names = settings.askLauncherSearchSettings
        let key = "\(preferences.enabled)\u{3}\(names.fileIndexFingerprint)\u{3}\(settings.askQuickFileSearchEnabled)"
        guard force || fingerprint != key else { return }
        countRefresh?.cancel(); countRefresh = nil; countRefreshID = nil
        resourceWaitReason = nil
        nextReason = reason ?? (fingerprint == nil ? .startup : (fingerprint == key ? .retry : .configuration))
        _ = pauseGate.takeDocuments()
        pausedIndexing = false; pausedReady = false
        pauseGate.setPaused(backgroundPaused)
        if fingerprint != key || !backgroundPaused {
            indexProgress = nil
        }
        currentProcessingPath = nil
        fingerprint = key
        token.cancel(); token = AskSearchCancellation()
        let token = token
        let previous = work
        work?.cancel(); rescan?.cancel(); watcher.stop()
        let previousJournal = eventJournal
        eventJournal = nil
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil; queryState = .idle
        scope = nil; store = nil; queryValidator = nil
        guard supported, preferences.enabled,
              settings.askQuickFileSearchEnabled else { download?.cancel(); phase = .off; return }
        if download != nil {
            return
        }
        mediaDownload = nil; mediaFailed = false
        phase = .preparing
        let directory = directory, model = modelURL, helper = helper, access = access, budget = budget
        let models = models
        work = Task { [weak self] in
            await previous?.value
            await Task.detached(priority: .utility) { previousJournal?.close() }.value
            guard !Task.isCancelled, !token.isCancelled else { return }
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    try budget.perform(cancelled: { token.isCancelled }, operation: {
                        guard !token.isCancelled else { throw CancellationError() }
                        let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: access())
                        let database = Result {
                            try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"),
                                                  cancelled: { token.isCancelled })
                        }
                        let events = try SemanticIndexEvents(url: directory
                            .appendingPathComponent("index-events.sqlite"))
                        return (scope, database, events)
                    })
                }.value
                let existing = try? prepared.1.get()
                let counts = if let existing {
                    await Self.readCounts(existing)
                } else {
                    nil as (
                        SemanticFileStore.Counts,
                        Bool
                    )?
                }
                guard !token.isCancelled, !Task.isCancelled else { return }
                self?.publishPreparation(scope: prepared.0, database: existing, events: prepared.2, counts: counts)
                guard FileManager.default.fileExists(atPath: model.path) else {
                    self?.modelReady = false; self?.phase = .modelRequired; return
                }
                try await Task.detached(priority: .utility) {
                    try budget.perform(cancelled: { token.isCancelled }, operation: {
                        try models.verify(model, cancelled: { token.isCancelled })
                    })
                }.value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                modelReady = true
                let database = try prepared.1.get()
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { phase = .failed; return }
                queryWorker = makeQuery(helper, model)
                if prewarmRequested {
                    prepareForSearch()
                }
                let events = prepared.2, eventScope = prepared.0
                watcher.start(paths: eventScope.roots, since: events.eventID) { [weak self] changes, eventID in
                    guard !token.isCancelled else { return }
                    do {
                        let changed = try events.append(changes, scope: eventScope, directory: directory.path,
                                                        eventID: eventID, cancelled: { token.isCancelled })
                        if changed, events.requestNotification() {
                            Task { @MainActor in self?.receiveChanges(events) }
                        }
                    } catch {
                        Task { @MainActor in
                            guard let self, !token.isCancelled else { return }
                            token.cancel(); self.work?.cancel(); self.watcher.stop(); self.phase = .failed
                        }
                    }
                }
                if backgroundPaused {
                    guard !token.isCancelled, !Task.isCancelled else { return }
                    phase = .paused
                    return
                }
                skipped = 0
                phase = .indexing
                beginIndexing(database, scope: prepared.0, token: token)

            } catch {
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                if case SemanticMediaFailure.unavailable = error {
                    mediaFailed = true
                }
                if case SemanticFileStore.Failure.invalidVector = error {
                    modelReady = false
                }
                phase = .failed
            }
        }
    }

    private static func readCounts(_ database: SemanticFileStore) async -> (SemanticFileStore.Counts, Bool)? {
        try? await Task.detached(priority: .utility, operation: {
            try (database.counts(), database.hasPublishedContent())
        }).value
    }

    private func publishPreparation(scope: AskFileScope, database: SemanticFileStore?, events: SemanticIndexEvents,
                                    counts: (SemanticFileStore.Counts, Bool)?) {
        self.scope = scope; blocked = scope.blockedInScope
        store = database; eventJournal = events
        queryValidator = SemanticFileValidator(reader: makeReader())
        if let database {
            publishCounts(counts, for: database)
        }
    }

    private func updateCounts(_ database: SemanticFileStore) async {
        await publishCounts(Self.readCounts(database), for: database)
    }

    private func publishCounts(_ result: (SemanticFileStore.Counts, Bool)?, for database: SemanticFileStore) {
        guard store === database else { return }
        if let result {
            let (counts, content) = result
            guard !removing, store === database else { return }
            hasPublishedContent = content
            if files != counts.files {
                files = counts.files
            }
            if chunks != counts.chunks {
                chunks = counts.chunks
            }
            if indexedCounts != counts {
                indexedCounts = counts
            }
        }
    }

    private func receiveChanges(_ events: SemanticIndexEvents) {
        guard eventJournal === events else { return }
        events.receivedNotification()
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard phase != .indexing, !backgroundPaused, let database = store, let events = eventJournal else { return }
        let includeQueued = phase == .ready, lifecycle = token
        rescan?.cancel()
        rescan = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let pending = await (try? Task.detached(priority: .utility) {
                try events.pending() || (includeQueued && database.hasQueuedWork())
            }.value) ?? false
            guard pending, let self, !lifecycle.isCancelled, store === database else { return }
            reconcilePending()
        }
    }

    private func reconcilePending() {
        guard !backgroundPaused, phase == .ready || phase == .failed,
              let database = store, let scope else { return }
        indexProgress = nil
        phase = .indexing
        beginIndexing(database, scope: scope, token: token, paths: [], reason: .filesystem)
    }

    deinit {
        token.cancel(); work?.cancel(); download?.cancel(); rescan?.cancel(); warmup?.cancel(); countRefresh?.cancel()
    }
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
                               paths: [String]? = nil, reason: SemanticIndexDiagnostics.Reason? = nil) {
        let makeReader = makeReader, makeEncoder = makeEncoder, mediaModels = mediaModels
        let makeMediaEncoder = makeMediaEncoder, helper = helper, model = modelURL
        let projector = mediaModelURL, idle = idle, pauseGate = pauseGate
        let events = eventJournal, reason = reason ?? nextReason, budget = budget
        let configuration = fingerprint ?? ""
        nextReason = .resume
        let documents: () throws -> SemanticIndexPauseGate.DocumentWork = {
            try events?.transfer(to: database)
            return pauseGate.takeDocuments()
        }
        let downloadRelay = SemanticProgressRelay<Double?> { [weak self] fraction in
            guard let self, !token.isCancelled else { return }
            mediaDownload = fraction
        }
        let reportDownload: @Sendable (Double?) -> Void = { downloadRelay.send($0) }
        let budgetStart = budget.statistics
        let currentRelay = SemanticProgressRelay<String?> { [weak self] path in
            guard let self, !token.isCancelled, phase == .indexing else { return }
            currentProcessingPath = path
        }
        let reportCurrent: @Sendable (String?) -> Void = { currentRelay.send($0) }
        let relay = SemanticIndexProgressRelay { [weak self] summary in
            guard let self, !token.isCancelled, store === database else { return }
            let priorityChanged = indexProgress?.priorityUpdates != summary.priorityUpdates
            indexProgress = summary; diagnostics = summary.diagnostics
            files = max(files, summary.files); skipped = summary.skipped
            if countRefresh == nil, priorityChanged || Date().timeIntervalSince(lastCountRefresh) >= 3 {
                lastCountRefresh = Date()
                let requestID = UUID()
                countRefreshID = requestID
                countRefresh = Task { [weak self] in
                    let value = await Self.readCounts(database)
                    guard let self else { return }
                    defer {
                        if countRefreshID == requestID {
                            countRefresh = nil; countRefreshID = nil
                        }
                    }
                    guard !Task.isCancelled, countRefreshID == requestID else { return }
                    publishCounts(value, for: database)
                }
            }
        }
        let reportProgress: @Sendable (SemanticFileIndexer.Summary) -> Void = { summary in
            try? database.updateBudget(budget.statistics, since: budgetStart)
            var summary = summary
            summary.diagnostics = try? database.runDiagnostics()
            relay.send(summary)
        }
        work = Task { [weak self] in
            defer { downloadRelay.close(); currentRelay.close() }
            let monitor = self?.monitorDiagnostics(database, token: token, budget: budget, since: budgetStart)
            do {
                let result = try await Task.detached(priority: .utility) {
                    try budget.perform(cancelled: { token.isCancelled }, operation: {
                        try database.beginRun(reason: reason, configuration: configuration)
                        var completed = false
                        defer {
                            try? database.updateBudget(budget.statistics, since: budgetStart)
                            try? database
                                .finishRun(stage: completed ? .complete : (token.isCancelled ? .cancelled : .failed))
                        }
                        let reader = makeReader(), priorityReader = makeReader()
                        let encoder = makeEncoder(helper, model)
                        let media = SemanticMediaWorker(helper: helper, model: model, projector: projector,
                                                        models: mediaModels, makeEncoder: makeMediaEncoder,
                                                        progress: reportDownload)
                        let result: SemanticFileIndexer.Summary = if let paths {
                            try SemanticFileIndexer.reconcile(
                                paths: paths, scope: scope, store: database, reader: reader,
                                encoder: encoder, media: media, idle: { idle() && !pauseGate.isPaused },
                                paused: { pauseGate.isPaused }, documents: documents,
                                priorityReader: priorityReader,
                                cancelled: { token.isCancelled }, progress: reportProgress, current: reportCurrent
                            )
                        } else {
                            try SemanticFileIndexer.run(scope: scope, store: database, reader: reader,
                                                        encoder: encoder, media: media,
                                                        idle: { idle() && !pauseGate.isPaused },
                                                        paused: { pauseGate.isPaused },
                                                        documents: documents,
                                                        priorityReader: priorityReader,
                                                        cancelled: { token.isCancelled },
                                                        progress: reportProgress, current: reportCurrent)
                        }
                        completed = true
                        return result
                    })
                }.value
                monitor?.cancel(); await monitor?.value
                relay.close()
                let finalDiagnostics = try? await Task.detached(priority: .utility) { try database.runDiagnostics() }
                    .value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                diagnostics = finalDiagnostics
                mediaDownload = nil
                skipped = result.skipped
                await countRefresh?.value
                await updateCounts(database)
                guard !token.isCancelled, !Task.isCancelled else { return }
                indexProgress = nil
                currentProcessingPath = nil
                if backgroundPaused {
                    pausedIndexing = false
                    pausedReady = true
                    phase = .paused
                } else {
                    phase = .ready
                }
                scheduleReconcile()
            } catch {
                monitor?.cancel(); await monitor?.value
                relay.close()
                let finalDiagnostics = try? await Task.detached(priority: .utility) { try database.runDiagnostics() }
                    .value
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                diagnostics = finalDiagnostics
                mediaDownload = nil
                currentProcessingPath = nil
                if case SemanticMediaFailure.unavailable = error {
                    mediaFailed = true
                }
                if case SemanticFileStore.Failure.invalidVector = error {
                    modelReady = false
                }
                phase = .failed
            }
        }
    }

    func downloadModel() {
        guard supported, download == nil, preferences.enabled else { return }
        let target = modelURL
        let models = models
        let progress = SemanticProgressRelay<Int64> { [weak self] in self?.reportModelDownload($0) }
        phase = .downloading(0)
        download = Task { [weak self] in
            defer { progress.close() }
            do {
                let (temporary, response) = try await models.fetch { progress.send($0) }
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
                guard let self else { return }
                download = nil; modelReady = true; start(force: true, reason: .modelInstalled)
            } catch {
                guard let self else { return }
                let cancelled = Task.isCancelled
                download = nil
                phase = !preferences.enabled ? .off : (cancelled ? .modelRequired : .failed)
            }
        }
    }

    private func reportModelDownload(_ received: Int64) {
        guard download != nil, preferences.enabled else { return }
        phase = .downloading(min(1, Double(received) / Double(SemanticModel.bytes)))
    }

    func cancelDownload() {
        download?.cancel()
    }

    func prepareModelIfNeeded() async {
        await work?.value
        if phase == .modelRequired {
            downloadModel()
        }
    }

    /// Stop every writer before removing artifacts. The name index is never touched.
    func clear(removeModel: Bool = false) async {
        guard !removing else { return }
        removing = true
        let pendingCounts = countRefresh
        pendingCounts?.cancel()
        _ = setEnabled(false)
        preferences = settings.semanticFileSearch
        token.cancel(); work?.cancel(); rescan?.cancel(); download?.cancel(); watcher.stop()
        warmup?.cancel(); warmup = nil
        queryWorker?.stop(); queryWorker = nil
        await work?.value; await download?.value; await pendingCounts?.value
        let database = store, events = eventJournal, directory = directory, model = modelURL, projector = mediaModelURL
        eventJournal = nil
        do {
            try await Task.detached(priority: .utility) {
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
        let scope = settings.askLauncherSearchSettings.fileIndexFingerprint
        await clear()
        // Scope edits during clearing win; never restore an outdated filename-search scope.
        guard phase == .off, settings.askLauncherSearchSettings.fileIndexFingerprint == scope else { return }
        _ = setEnabled(true)
        nextReason = .rebuild
    }

    func processingPage(_ section: SemanticFileStore.ProcessingSection, offset: Int,
                        limit: Int = 50) async -> SemanticFileStore.ProcessingPage? {
        guard let database = store else { return nil }
        let page = try? await Task.detached(priority: .utility) {
            try database.processingPage(section, offset: offset, limit: limit)
        }.value
        guard store === database else { return nil }
        return page
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
        let lifecycle = token, preparation = AskSearchCancellation(), gate = pauseGate, store = modelReady ? store : nil
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
        // Lexical lookup and current-permission validation also own foreground priority.
        pauseGate.beginQuery()
        defer {
            pauseGate.endQuery()
            if generation == queryGeneration, queryState == .searching {
                queryState = .idle
            }
        }
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
