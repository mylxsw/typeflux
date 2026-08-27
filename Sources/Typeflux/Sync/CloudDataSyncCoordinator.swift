import AppKit
import Foundation
import Network
import os

@MainActor
final class CloudDataSyncCoordinator: ObservableObject {
    static let shared = CloudDataSyncCoordinator()

    @Published private(set) var isEnabled = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?

    private let authState: AuthState
    private let settingsStore: SettingsStore
    private let store: SQLiteCloudDataSyncStore
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "typeflux.cloud-data-sync.network")
    private var observers: [NSObjectProtocol] = []
    private var periodicTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var applyingRemote = false

    private static let deviceID: UUID = {
        let key = "cloudDataSync.deviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    init(
        authState: AuthState? = nil,
        settingsStore: SettingsStore = SettingsStore(),
        store: SQLiteCloudDataSyncStore = SQLiteCloudDataSyncStore()
    ) {
        self.authState = authState ?? .shared
        self.settingsStore = settingsStore
        self.store = store
        observe()
        refreshEnabledState()
        startPeriodicSync()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        monitor.cancel()
        periodicTask?.cancel()
        debounceTask?.cancel()
        syncTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard let userID = authState.userProfile?.id else { return }
        store.setEnabled(enabled, userID: userID)
        isEnabled = enabled
        lastError = nil
        if enabled { synchronizeNow() } else {
            debounceTask?.cancel()
            syncTask?.cancel()
            isSyncing = false
        }
    }

    func synchronizeNow() {
        guard syncTask == nil, syncContext() != nil else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            await performSync()
            syncTask = nil
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        for name in [Notification.Name.authDidLogin, .authDidLogout] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshEnabledState()
                    self?.synchronizeNow()
                }
            })
        }
        for name in [Notification.Name.vocabularyStoreDidChange, .personaStoreDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleLocalPush() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.synchronizeNow() }
            })
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.synchronizeNow() }
        }
        monitor.start(queue: monitorQueue)
    }

    private func refreshEnabledState() {
        guard let userID = authState.userProfile?.id else {
            isEnabled = false
            debounceTask?.cancel()
            syncTask?.cancel()
            syncTask = nil
            isSyncing = false
            return
        }
        isEnabled = store.state(userID: userID).enabled
    }

    private func startPeriodicSync() {
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.synchronizeNow()
            }
        }
    }

    private func scheduleLocalPush() {
        guard !applyingRemote, syncContext() != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.synchronizeNow()
        }
    }

    private func syncContext() -> (userID: String, token: String, state: SQLiteCloudDataSyncStore.State)? {
        guard let userID = authState.userProfile?.id, let token = authState.accessToken else { return nil }
        let state = store.state(userID: userID)
        guard state.enabled else { return nil }
        return (userID, token, state)
    }

    private func performSync() async {
        guard var context = syncContext() else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try stageLocalData(userID: context.userID)
            var hasMore = true
            while hasMore, !Task.isCancelled {
                let pending = store.pending(userID: context.userID)
                let response = try await CloudDataSyncAPIService.sync(
                    token: context.token,
                    request: CloudSyncRequest(
                        deviceID: Self.deviceID, cursor: context.state.cursor,
                        ackCursor: context.state.cursor, checkpoint: context.state.checkpoint,
                        mutations: pending
                    )
                )
                try resolve(results: response.results, mutations: pending, userID: context.userID)
                try apply(changes: response.changes, userID: context.userID)
                store.accept(response.results, mutations: pending, userID: context.userID)
                store.setProgress(userID: context.userID, cursor: response.cursor,
                                  checkpoint: response.hasMore ? response.checkpoint : 0)
                context.state.cursor = response.cursor
                context.state.checkpoint = response.hasMore ? response.checkpoint : 0
                hasMore = response.hasMore
            }
            lastSyncAt = Date()
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
            Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudDataSync")
                .error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stageLocalData(userID: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let vocabulary = try Dictionary(uniqueKeysWithValues: VocabularyStore.load().map { entry in
            (entry.id, try encoder.encode(VocabularyCloudPayload(
                term: entry.term, source: entry.source.rawValue,
                createdAt: entry.createdAt, occurrenceCount: entry.occurrenceCount
            )))
        })
        let personas = try Dictionary(
            uniqueKeysWithValues: settingsStore.personas.filter { !$0.isSystem }.map { persona in
                (persona.id, try encoder.encode(PersonaCloudPayload(name: persona.name, prompt: persona.prompt)))
            }
        )
        store.stageLocalChanges(userID: userID, type: .vocabulary, entities: vocabulary)
        store.stageLocalChanges(userID: userID, type: .persona, entities: personas)
    }

    private func resolve(results: [CloudSyncMutationResult], mutations: [CloudSyncMutation], userID: String) throws {
        let byID = Dictionary(uniqueKeysWithValues: mutations.map { ($0.mutationID, $0) })
        for result in results where result.status != "accepted" {
            guard let mutation = byID[result.mutationID] else { continue }
            if mutation.entityType == .persona, mutation.operation != "delete" {
                let payload = try JSONDecoder().decode(PersonaCloudPayload.self, from: mutation.payload)
                var personas = settingsStore.personas
                personas.append(PersonaProfile(name: payload.name + " (冲突副本)", prompt: payload.prompt))
                applyingRemote = true
                settingsStore.personas = personas
                applyingRemote = false
            } else if mutation.entityType == .vocabulary, let current = result.current {
                try applyVocabulary(id: result.canonicalID, payload: current.data, deleted: false)
                store.apply(change: CloudSyncChange(
                    sequence: 0, entityType: .vocabulary, entityID: result.canonicalID,
                    operation: "update", revision: result.revision, payload: current
                ), userID: userID)
            }
        }
    }

    private func apply(changes: [CloudSyncChange], userID: String) throws {
        applyingRemote = true
        defer { applyingRemote = false }
        for change in changes {
            switch change.entityType {
            case .vocabulary:
                try applyVocabulary(
                    id: change.entityID, payload: change.payload.data,
                    deleted: change.operation == "delete"
                )
            case .persona:
                try applyPersona(
                    id: change.entityID, payload: change.payload.data,
                    deleted: change.operation == "delete"
                )
            }
            store.apply(change: change, userID: userID)
        }
    }

    private func applyVocabulary(id: UUID, payload: Data, deleted: Bool) throws {
        var entries = VocabularyStore.load()
        entries.removeAll { $0.id == id }
        if !deleted {
            let value = try JSONDecoder.cloudSyncDates.decode(VocabularyCloudPayload.self, from: payload)
            entries.removeAll {
                $0.term.compare(value.term, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
            }
            entries.append(VocabularyEntry(
                id: id, term: value.term, source: VocabularySource(rawValue: value.source) ?? .manual,
                createdAt: value.createdAt, occurrenceCount: value.occurrenceCount
            ))
        }
        VocabularyStore.save(entries)
    }

    private func applyPersona(id: UUID, payload: Data, deleted: Bool) throws {
        var personas = settingsStore.personas
        personas.removeAll { $0.id == id && !$0.isSystem }
        if !deleted {
            let value = try JSONDecoder().decode(PersonaCloudPayload.self, from: payload)
            personas.append(PersonaProfile(id: id, name: value.name, prompt: value.prompt))
        }
        settingsStore.personas = personas
    }
}

private extension JSONDecoder {
    static var cloudSyncDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
