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
    @Published private(set) var requiresInitialChoice = false

    private let authState: AuthState
    private let settingsStore: SettingsStore
    private let store: SQLiteCloudDataSyncStore
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "typeflux.cloud-data-sync.network")
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var periodicTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var applyingRemote = false
    private var localChangeDuringSync = false
    private var syncGeneration = 0

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
        refreshEnabledState(switchScope: true)
        startPeriodicSync()
        synchronizeNow()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        monitor.cancel()
        periodicTask?.cancel()
        debounceTask?.cancel()
        syncTask?.cancel()
    }

    func setEnabled(_ enabled: Bool, mergeGuestData: Bool = true) {
        guard let userID = authState.userProfile?.id else { return }
        guard store.isAvailable else {
            lastError = store.initializationError?.localizedDescription ?? "Local sync storage is unavailable"
            return
        }
        if enabled && !store.hasAccount(userID: userID) {
            prepareInitialAccountScope(userID: userID, mergeGuestData: mergeGuestData)
        }
        store.setEnabled(enabled, userID: userID)
        isEnabled = enabled
        requiresInitialChoice = false
        lastError = nil
        if enabled { synchronizeNow() } else {
            syncGeneration += 1
            debounceTask?.cancel()
            syncTask?.cancel()
            syncTask = nil
            isSyncing = false
        }
    }

    func synchronizeNow() {
        guard syncTask == nil, syncContext() != nil else { return }
        let generation = syncGeneration
        syncTask = Task { [weak self] in
            guard let self else { return }
            await performSync()
            guard generation == syncGeneration else { return }
            syncTask = nil
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshEnabledState(switchScope: true)
                    self?.synchronizeNow()
                }
            })
        }
        for name in [Notification.Name.vocabularyStoreDidChange, .personaStoreDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleLocalPush() }
            })
        }
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeNow() }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeNow() }
        })
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.synchronizeNow() }
        }
        monitor.start(queue: monitorQueue)
    }

    private func refreshEnabledState(switchScope: Bool = false) {
        guard let userID = authState.userProfile?.id else {
            if switchScope { switchToGuestScope() }
            isEnabled = false
            requiresInitialChoice = false
            syncGeneration += 1
            debounceTask?.cancel()
            syncTask?.cancel()
            syncTask = nil
            isSyncing = false
            return
        }
        let hasAccount = store.hasAccount(userID: userID)
        isEnabled = store.state(userID: userID).enabled
        requiresInitialChoice = !hasAccount
        if switchScope {
            applyingRemote = true
            if hasAccount { CloudDataLocalScope.useAccount(userID) } else { CloudDataLocalScope.useGuest() }
            applyingRemote = false
            postScopeChangeNotifications()
        }
    }

    private func prepareInitialAccountScope(userID: String, mergeGuestData: Bool) {
        applyingRemote = true
        let guestVocabulary = VocabularyStore.load()
        let guestPersonas = settingsStore.personas.filter { !$0.isSystem }
        CloudDataLocalScope.useAccount(userID)
        if mergeGuestData {
            VocabularyStore.save(mergeVocabulary(VocabularyStore.load(), guestVocabulary))
            var personas = settingsStore.personas
            for guest in guestPersonas where !personas.contains(where: { $0.id == guest.id }) {
                personas.append(guest)
            }
            settingsStore.personas = personas
        } else {
            VocabularyStore.save([])
            settingsStore.personas = []
        }
        applyingRemote = false
        postScopeChangeNotifications()
    }

    private func switchToGuestScope() {
        applyingRemote = true
        CloudDataLocalScope.useGuest()
        applyingRemote = false
        postScopeChangeNotifications()
    }

    private func postScopeChangeNotifications() {
        NotificationCenter.default.post(name: .vocabularyStoreDidChange, object: nil)
        NotificationCenter.default.post(name: .personaStoreDidChange, object: settingsStore)
    }

    private func mergeVocabulary(
        _ account: [VocabularyEntry], _ guest: [VocabularyEntry]
    ) -> [VocabularyEntry] {
        var result = account
        for entry in guest {
            if let index = result.firstIndex(where: {
                $0.term.compare(entry.term, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
            }) {
                let existing = result[index]
                result[index] = VocabularyEntry(
                    id: existing.id, term: existing.term,
                    source: existing.source == .manual ? existing.source : entry.source,
                    createdAt: min(existing.createdAt, entry.createdAt),
                    occurrenceCount: max(existing.occurrenceCount, entry.occurrenceCount)
                )
            } else {
                result.append(entry)
            }
        }
        return result
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
        if syncTask != nil { localChangeDuringSync = true }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.synchronizeNow()
        }
    }

    private func syncContext() -> (userID: String, token: String, state: SQLiteCloudDataSyncStore.State)? {
        guard store.isAvailable else { return nil }
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
                localChangeDuringSync = false
                let response = try await CloudDataSyncAPIService.sync(
                    token: context.token,
                    request: CloudSyncRequest(
                        deviceID: Self.deviceID, cursor: context.state.cursor,
                        ackCursor: context.state.cursor, checkpoint: context.state.checkpoint,
                        mutations: pending
                    )
                )
                try resolve(
                    results: response.results, mutations: pending, userID: context.userID,
                    applyAccepted: !localChangeDuringSync
                )
                store.accept(
                    response.results, mutations: pending, userID: context.userID,
                    removeRejected: !localChangeDuringSync
                )
                if localChangeDuringSync {
                    // A local edit landed while the request was in flight. Keep the old cursor so
                    // the response can be replayed after that newer local intent has been staged.
                    try stageLocalData(userID: context.userID)
                    hasMore = true
                    continue
                }
                try apply(changes: response.changes, userID: context.userID)
                store.setProgress(userID: context.userID, cursor: response.cursor,
                                  checkpoint: response.hasMore ? response.checkpoint : 0)
                context.state.cursor = response.cursor
                context.state.checkpoint = response.hasMore ? response.checkpoint : 0
                try stageLocalData(userID: context.userID)
                hasMore = response.hasMore || !store.pending(userID: context.userID).isEmpty
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

    private func resolve(
        results: [CloudSyncMutationResult], mutations: [CloudSyncMutation], userID: String,
        applyAccepted: Bool
    ) throws {
        applyingRemote = true
        defer { applyingRemote = false }
        let byID = Dictionary(uniqueKeysWithValues: mutations.map { ($0.mutationID, $0) })
        for result in results {
            guard let mutation = byID[result.mutationID] else { continue }
            if result.status == "invalid" {
                throw CloudDataSyncError.invalidMutation(result.message ?? "Invalid cloud sync data")
            }
            if result.status == "accepted" {
                if let current = result.current, applyAccepted {
                    try applyCurrent(result: result, mutation: mutation, payload: current, userID: userID)
                }
                continue
            }
            guard applyAccepted else { continue }
            if mutation.entityType == .persona, mutation.operation != "delete" {
                let payload = try JSONDecoder().decode(PersonaCloudPayload.self, from: mutation.payload)
                var personas = settingsStore.personas
                personas.removeAll { $0.id == result.mutationID && !$0.isSystem }
                let conflictSuffix = " (冲突副本)"
                let conflictName = String(payload.name.prefix(max(0, 100 - conflictSuffix.count)))
                    + conflictSuffix
                personas.append(PersonaProfile(
                    id: result.mutationID, name: conflictName, prompt: payload.prompt
                ))
                settingsStore.personas = personas
                if let current = result.current {
                    try applyPersona(id: result.canonicalID, payload: current.data, deleted: result.deleted)
                    store.apply(change: syntheticChange(result: result, type: .persona), userID: userID)
                } else {
                    try applyPersona(id: mutation.entityID, payload: mutation.payload, deleted: true)
                }
            } else if mutation.entityType == .persona, let current = result.current {
                try applyPersona(id: result.canonicalID, payload: current.data, deleted: result.deleted)
                store.apply(change: syntheticChange(result: result, type: .persona), userID: userID)
            } else if mutation.entityType == .vocabulary, let current = result.current {
                try applyVocabulary(id: result.canonicalID, payload: current.data, deleted: result.deleted)
                store.apply(change: syntheticChange(result: result, type: .vocabulary), userID: userID)
            }
        }
    }

    private func applyCurrent(
        result: CloudSyncMutationResult, mutation: CloudSyncMutation, payload: JSONValue, userID: String
    ) throws {
        switch mutation.entityType {
        case .vocabulary:
            try applyVocabulary(id: result.canonicalID, payload: payload.data, deleted: result.deleted)
        case .persona:
            try applyPersona(id: result.canonicalID, payload: payload.data, deleted: result.deleted)
        }
        store.apply(change: syntheticChange(result: result, type: mutation.entityType), userID: userID)
    }

    private func syntheticChange(
        result: CloudSyncMutationResult, type: CloudSyncEntityType
    ) -> CloudSyncChange {
        CloudSyncChange(
            sequence: 0, entityType: type, entityID: result.canonicalID,
            operation: result.deleted ? "delete" : "update", revision: result.revision,
            payload: result.current ?? JSONValue(data: Data("{}".utf8))
        )
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
        if deleted {
            if settingsStore.activePersonaID == id.uuidString {
                settingsStore.activePersonaID = ""
            }
            settingsStore.personaAppBindings.removeAll { $0.personaID == id }
        }
    }
}

private enum CloudDataSyncError: LocalizedError {
    case invalidMutation(String)

    var errorDescription: String? {
        switch self {
        case .invalidMutation(let message): message
        }
    }
}

private extension JSONDecoder {
    static var cloudSyncDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
