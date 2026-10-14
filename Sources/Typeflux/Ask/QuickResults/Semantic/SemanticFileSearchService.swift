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
    @Published private(set) var skipped = 0
    @Published private(set) var limited = false
    @Published private(set) var indexProgress: SemanticFileIndexer.Summary?
    @Published private(set) var blocked: [String] = []
    @Published private(set) var modelReady = false
    @Published private(set) var preferences: SemanticFileSettings
    let supported: Bool
    var isEnabled: Bool {
        supported && preferences.enabled && settings.askQuickFileSearchEnabled && phase == .ready
    }
    let settings: SettingsStore
    private let directory: URL
    private let helper: URL
    private let watcher: AskFileWatching
    private let access: @Sendable () -> Bool
    private let resourceConstrained: @Sendable () -> Bool
    private let models: any SemanticModelHandling
    private let makeReader: @Sendable () -> any AskFileReading
    private let makeEncoder: @Sendable (URL, URL) -> any SemanticEmbedding
    private let makeQuery: @Sendable (URL, URL) -> any SemanticQueryEmbedding
    private var observers: [AnyCancellable] = []
    private var work: Task<Void, Never>?
    private var download: Task<Void, Never>?
    private var rescan: Task<Void, Never>?
    private var token = AskSearchCancellation()
    private var store: SemanticFileStore?
    private var scope: AskFileScope?
    private var queryWorker: (any SemanticQueryEmbedding)?
    private var fingerprint: String?
    private var busy = false
    private var manuallyPaused = false
    private var dirty = false
    private var removing = false
    var modelURL: URL {
        self.directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
    }

    init(settings: SettingsStore, directory: URL = SemanticModel.directory, helper: URL = SemanticModel.helperURL,
         supported: Bool = SemanticFilePolicy.supported, watcher: AskFileWatching = AskFSEventsWatcher(),
         access: @escaping @Sendable () -> Bool = { AskFullDiskAccess.isGranted() }, automaticStart: Bool = true,
         resourceConstrained: @escaping @Sendable () -> Bool = {
             ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= 2
         },
         models: any SemanticModelHandling = SemanticModelFiles(),
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
                Task { @MainActor in self?.start(force: true) }
            })
        self.observers
            .append(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.start(force: true) }
                })
        self.start()
    }

    private var backgroundPaused: Bool {
        self.busy || self.manuallyPaused || self.resourceConstrained()
    }

    func setForegroundBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy
        self.start(force: true)
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
        self.manuallyPaused = paused; self.start(force: true)
    }

    // Keep generation checks beside every suspension in this lifecycle transition.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func start(force: Bool = false) {
        guard !self.removing else { return }
        preferences = self.settings.semanticFileSearch
        let names = self.settings.askLauncherSearchSettings
        let key = String(describing: preferences) + String(describing: names) +
            String(self.settings.askQuickFileSearchEnabled)
        guard force || self.fingerprint != key else { return }
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
        self.phase = .preparing
        let directory = directory, model = self.modelURL, helper = helper, access = access
        let models = models, makeReader = makeReader, makeEncoder = makeEncoder
        let paused = self.backgroundPaused
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
                self.queryWorker = self.makeQuery(helper, model)
                self.watcher.start(paths: prepared.0.roots, since: nil) { [weak self] _, _ in
                    Task { @MainActor in self?.scheduleReconcile() }
                }
                if paused {
                    guard !token.isCancelled, !Task.isCancelled else { return }
                    self.phase = .paused
                    return
                }
                self.limited = false; self.skipped = 0
                self.phase = .indexing
                let result = try await Task.detached(priority: .utility) { [weak self] in
                    let reader = makeReader()
                    let encoder = makeEncoder(helper, model)
                    return try SemanticFileIndexer.run(
                        scope: prepared.0,
                        store: database,
                        reader: reader,
                        encoder: encoder,
                        cancelled: { token.isCancelled }, progress: { summary in
                            Task { @MainActor [weak self] in
                                guard let self, !token.isCancelled else { return }
                                self.indexProgress = summary
                                self.files = max(self.files, summary.files); self.skipped = summary.skipped
                            }
                        }
                    )
                }.value
                guard !token.isCancelled, !Task.isCancelled else { return }
                self.skipped = result.skipped; self.limited = result.limited
                await self.updateCounts(database)
                guard !token.isCancelled, !Task.isCancelled else { return }
                self.indexProgress = nil
                self.phase = .ready
                if self.dirty {
                    self.dirty = false; self.scheduleReconcile()
                }
            } catch {
                guard let self, !token.isCancelled, !Task.isCancelled else { return }
                if case SemanticFileStore.Failure.invalidVector = error {
                    self.modelReady = false
                }
                self.phase = .failed
            }
        }
    }

    private func updateCounts(_ database: SemanticFileStore) async {
        if let counts = try? await Task.detached(priority: .utility, operation: { try database.counts() }).value {
            self.files = counts.files; self.chunks = counts.chunks
        }
    }

    private func scheduleReconcile() {
        if self.phase == .indexing {
            self.dirty = true; return
        }
        self.rescan?.cancel()
        self.rescan = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.start(force: true)
        }
    }

    deinit { token.cancel(); work?.cancel(); download?.cancel(); rescan?.cancel() }
}

extension SemanticFileSearchService {
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
        let database = self.store, directory = directory, model = self.modelURL
        do {
            try await Task.detached(priority: .utility) {
                if let database {
                    try database.destroy()
                } else {
                    try SemanticFileStore.removeFiles(at: directory.appendingPathComponent("semantic-files.sqlite"))
                }
                if removeModel,
                   FileManager.default.fileExists(atPath: model.path) {
                    try FileManager.default.removeItem(at: model)
                }
            }.value
            self.files = 0; self.chunks = 0; self.skipped = 0; self.limited = false
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
        return (index, size(self.modelURL))
    }

    func rebuild() async {
        let scope = self.settings.askLauncherSearchSettings.fileIndexFingerprint
        await self.clear()
        // Scope edits during clearing win; never restore an outdated filename-search scope.
        guard self.phase == .off, self.settings.askLauncherSearchSettings.fileIndexFingerprint == scope else { return }
        _ = self.setEnabled(true)
    }
}
