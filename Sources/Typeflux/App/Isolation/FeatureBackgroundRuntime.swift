import AppKit
import Combine
import Foundation

struct FeatureFileQuery: Codable, Sendable {
    let text: String?
    let limit: Int
    let fuzzy: Bool
    let type: AskFileType
    let order: AskFileSearchOptions.Order
    let now: Date
}

struct FeatureSemanticQuery: Codable, Sendable {
    let text: String
    let type: AskFileType
    let limit: Int
}

struct FeatureProcessingPage: Codable, Sendable {
    let section: SemanticFileStore.ProcessingSection
    let offset: Int
    let limit: Int
}

struct FeatureSemanticSnapshot: Codable, Sendable {
    let phase: SemanticFileSearchService.Phase
    let files: Int
    let chunks: Int
    let hasPublishedContent: Bool
    let indexedCounts: SemanticFileStore.Counts
    let skipped: Int
    let mediaDownload: Double?
    let mediaFailed: Bool
    let resourceWaitReason: SemanticWorkBudget.Waiting?
    let diagnostics: SemanticIndexDiagnostics?
    let indexProgress: SemanticFileIndexer.Summary?
    let currentProcessingPath: String?
    let blocked: [String]
    let modelReady: Bool
    let preferences: SemanticFileSettings
    let queryState: SemanticFileSearchService.QueryState
    let manuallyPaused: Bool
    let enabled: Bool
}

struct FeatureIndexSnapshot: Codable, Sendable {
    let names: AskFileIndexStatus
    let content: FeatureSemanticSnapshot
}

final class FeatureIndexStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AskFileIndexStatus()
    var value: AskFileIndexStatus {
        lock.withLock { stored }
    }

    func update(_ value: AskFileIndexStatus) -> Bool {
        lock.withLock {
            guard stored != value else { return false }
            stored = value
            return true
        }
    }
}

/// Synchronous filename lookup is used only by the existing search queue. The UI
/// never waits on a semaphore. Both wire requests and the bridge have deadlines.
enum FeatureBackgroundCall {
    @MainActor
    static func request<Result: Decodable & Sendable>(_ command: FeatureCommand) async throws -> Result {
        let data = try await FeatureProcess.route(command, timeout: .seconds(120))
        return try JSONDecoder().decode(Result.self, from: data)
    }

    static func blocking<Result: Decodable & Sendable>(
        _ command: FeatureCommand,
        cancelled: @escaping @Sendable () -> Bool = { false },
        timeout: TimeInterval = 8,
        cancellationCommand: FeatureCommand? = nil
    ) -> Result? {
        guard !Thread.isMainThread, !cancelled() || cancellationCommand != nil else { return nil }
        let box = Reply<Result>()
        let done = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in
            defer { done.signal() }
            await box.set(try? request(command))
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var cancellationSent = false
        while done.wait(timeout: .now() + 0.02) == .timedOut {
            if cancelled() {
                guard let cancellationCommand else { return nil }
                if !cancellationSent {
                    cancellationSent = true
                    Task { @MainActor in _ = try? await FeatureProcess.route(cancellationCommand) }
                }
            }
            if ContinuousClock.now >= deadline {
                return nil
            }
        }
        return box.value
    }

    private final class Reply<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? {
            lock.withLock { stored }
        }

        func set(_ value: Value?) {
            lock.withLock { stored = value }
        }
    }
}

/// No application DI, recorder, history store, conversation model or window is
/// constructed here. This is the sole owner of both persisted search indexes.
@MainActor
final class FeatureBackgroundRuntime {
    static let shared = FeatureBackgroundRuntime()
    private let names: AskFileIndex
    private let content: SemanticFileSearchService
    private let healthDirectory: URL?
    private let publish: @MainActor (FeatureCommand) -> Void
    private let media: FeatureMediaJobs
    init(names: AskFileIndex = .shared, content: SemanticFileSearchService = .shared, media: FeatureMediaJobs? = nil,
         healthDirectory: URL? = nil, publish: @escaping @MainActor (FeatureCommand) -> Void = { FeatureProcess.send($0) }) {
        self.names = names; self.content = content; self.media = media ?? FeatureMediaJobs()
        self.healthDirectory = healthDirectory; self.publish = publish
    }

    private var healthObservations: [Task<Void, Never>] = []
    private var registry: ModuleRegistry?
    private var retainedModules: [AnyObject] = []
    private var subscriptions: [AnyCancellable] = []
    private var idleTask: Task<Void, Never>?
    private var idlePolicy = FeatureIdlePolicy()
    private var publication: Task<Void, Never>?
    private var stopped = false
    private var busyOwners = Set<String>()
    private var busyEpochs: [String: TimeInterval] = [:]
    var isForegroundBusy: Bool { !busyOwners.isEmpty }

    func start() {
        media.onBusy = { [weak self] busy in self?.setBusy("media", busy: busy) }
        let directory = healthDirectory ?? ModuleHealthStore.directory()
        let files = FileIndexModule(index: names, healthDirectory: directory)
        let readers = SemanticReaderModules(readers: content.readers, healthDirectory: directory)
        let models = SemanticModelModules(readers: content.embeddingOwners, healthDirectory: directory)
        retainedModules = [files, readers, models]
        let registry = ModuleRegistry([files.registration] + readers.registrations + models.registrations)
        self.registry = registry
        for entry in registry.registrations {
            healthObservations.append(Task { [weak self] in
                guard let stream = try? entry.health.observe() else { return }
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    self?.schedulePublication()
                }
            })
        }
        FeatureProcess.handle = { [weak self] command in
            guard let self, !stopped || command.action == "shutdown" else { throw FeatureRPC.Failure.unavailable }
            return try await handle(command)
        }
        let preparation = Task {
            _ = await registry.startAll()
            guard !Task.isCancelled, !stopped else { return }
            names.start()
            await content.startForApplication(using: registry, startModules: false)
            schedulePublication()
        }
        FeatureProcess.configure(api: AskAPIClient(), preparation: preparation)
        idleTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if idlePolicy.shouldRetire(
                    role: .background,
                    blocked: !allowsRetirement,
                    uptime: ProcessInfo.processInfo.systemUptime
                ) {
                    _ = try? await FeatureProcess.route(.init(
                        destination: .host,
                        action: "retireFeature",
                        payload: Data("background".utf8)
                    ))
                }
            }
        }
        subscriptions.append(content.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.schedulePublication() }
        })
        subscriptions.append(NotificationCenter.default.publisher(for: AskFileIndex.didChange).sink { [weak self] _ in
            Task { @MainActor in self?.schedulePublication() }
        })
    }

    private var hasOwnedHelpers: Bool {
        let readers = content.readers
        return FeatureHelperBudget.shared.activeCount > 0 || names.readerOwnership.isOccupied ||
            readers.validation.isOccupied || readers.indexing.isOccupied || readers.priority.isOccupied
    }

    private var allowsRetirement: Bool {
        names.status.phase == .off && content.phase == .off && !media.isBusy && !isForegroundBusy && FeatureHelperBudget.shared
            .activeCount == 0
    }

    private func setBusy(_ owner: String, busy: Bool, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard uptime.isFinite, uptime >= 0, uptime >= (busyEpochs[owner] ?? 0) else { return }
        busyEpochs[owner] = uptime
        if busy { busyOwners.insert(owner) } else { busyOwners.remove(owner) }
        content.setForegroundBusy(isForegroundBusy)
    }

    private func schedulePublication() {
        guard !stopped, publication == nil else { return }
        publication = Task {
            defer { publication = nil }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let health = Dictionary(uniqueKeysWithValues: registry?.registrations.compactMap { entry -> (
                ModuleID,
                ModuleHealth
            )? in
                entry.health.current.map { (entry.id, $0) }
            } ?? [])
            if let payload = try? JSONEncoder().encode(FeatureStatus(role: .background, activity: .init(), pins: 0,
                                                                     clickThroughPins: 0, voiceStatus: nil,
                                                                     modules: health)) {
                publish(.init(destination: .host, action: "status", payload: payload))
            }
            let snapshot = FeatureIndexSnapshot(names: names.status, content: content.backgroundSnapshot())
            if let payload = try? JSONEncoder().encode(snapshot) {
                publish(.init(destination: .host, action: "indexSnapshot", payload: payload))
            }
        }
    }

    func handle(_ command: FeatureCommand) async throws -> Data {
        func encode(_ value: some Encodable) throws -> Data {
            try JSONEncoder().encode(value)
        }
        func bool() throws -> Bool {
            try JSONDecoder().decode(Bool.self, from: command.payload)
        }
        if command.action.hasPrefix("semantic.busy.") {
            let activity: FeatureForegroundActivity
            if let value = try? JSONDecoder().decode(FeatureForegroundActivity.self, from: command.payload) { activity = value }
            else { activity = FeatureForegroundActivity(busy: try bool()) }
            setBusy(String(command.action.dropFirst("semantic.busy.".count)), busy: activity.busy, uptime: activity.uptime)
            return try encode(FeatureRPC.Empty())
        }
        if command.action == "media.wait" {
            return try await media.wait(command)
        }
        if command.action.hasPrefix("media.") {
            return try media.handle(command)
        }
        defer { schedulePublication() }
        #if DEBUG
            if FeatureIsolationProbe.enabled {
                if command.action == "probeExercise" {
                    return try encode(getpid())
                }
                if command.action == "probeFreeze" {
                    let seconds = try JSONDecoder().decode(Double.self, from: command.payload)
                    guard seconds > 0, seconds <= 10 else { throw FeatureRPC.Failure.invalidMessage }
                    FeatureIsolationProbe.blockMainThread(seconds: seconds)
                    return Data()
                }
            }
        #endif
        switch command.action {
        case "idleAllowed": return try encode(allowsRetirement)
        case "ping": break
        case "settings": names.start(); content.start(force: true)
        case "shutdown":
            stopped = true
            idleTask?.cancel(); try await media.shutdown(); healthObservations.forEach { $0.cancel() }
            publication?.cancel(); subscriptions.removeAll()
            registry?.preventNewWork()
            names.suspendWorker(); content.readers.stop(); content.embeddingOwners.stop()
            await registry?.shutdown()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while hasOwnedHelpers, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard !hasOwnedHelpers else { throw FeatureRPC.Failure.busy }
        case "recoverModule":
            let request = try JSONDecoder().decode(FeatureModuleRecovery.self, from: command.payload)
            guard let entry = registry?.registrations.first(where: { $0.id == request.id })
            else { throw FeatureRPC.Failure.invalidMessage }
            return try await encode(entry.recover(request.reset))
        case "files.start": names.start()
        case "files.rebuild": names.rebuild()
        case "files.clear": names.clear()
        case "files.open": names.recordOpen(String(decoding: command.payload, as: UTF8.self))
        case "files.forget": names.forget(String(decoding: command.payload, as: UTF8.self))
        case "files.search":
            let query = try JSONDecoder().decode(FeatureFileQuery.self, from: command.payload)
            guard query.text?.utf8.count ?? 0 <= 4096,
                  (0 ... 100).contains(query.limit) else { throw FeatureRPC.Failure.invalidMessage }
            let names = names, cancellation = AskSearchCancellation()
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    let options = AskFileSearchOptions(limit: query.limit, fuzzy: query.fuzzy, type: query.type,
                                                       order: query.order, now: query.now, cancellation: cancellation)
                    if let text = query.text {
                        return names.search(AskSearchQuery(text), options: options)
                    }
                    return names.recent(options: options)
                }.value
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            return try encode(result)
        case "semantic.start": try content.start(force: bool())
        case "semantic.enabled": return try encode(content.setEnabled(bool()))
        case "semantic.pause": try content.pause(bool())
        case "semantic.busy": try content.setForegroundBusy(bool())
        case "semantic.rescan": content.rescanAll()
        case "semantic.download": content.downloadModel()
        case "semantic.cancelDownload": content.cancelDownload()
        case "semantic.prepare": await content.prepareModelIfNeeded()
        case "semantic.clear": try await content.clear(removeModel: bool())
        case "semantic.rebuild": await content.rebuild()
        case "semantic.endSearch": content.endSearch()
        case "semantic.prepareSearch": content.prepareForSearch()
        case "semantic.page":
            let request = try JSONDecoder().decode(FeatureProcessingPage.self, from: command.payload)
            return try await encode(content.processingPage(
                request.section,
                offset: max(0, request.offset),
                limit: min(100, max(1, request.limit))
            ))
        case "semantic.retry":
            return try await encode(content.retryProcessingItem(JSONDecoder().decode(
                SemanticFileStore.ProcessingItem.self,
                from: command.payload
            )))
        case "semantic.search":
            let query = try JSONDecoder().decode(FeatureSemanticQuery.self, from: command.payload)
            guard query.text.utf8.count <= 4096,
                  (0 ... 100).contains(query.limit) else { throw FeatureRPC.Failure.invalidMessage }
            return try await encode(content.search(query.text, type: query.type, limit: query.limit))
        default: throw FeatureRPC.Failure.invalidMessage
        }
        return try encode(FeatureRPC.Empty())
    }
}
