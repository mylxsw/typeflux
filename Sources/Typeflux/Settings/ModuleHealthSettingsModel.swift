import SwiftUI

@MainActor
final class ModuleHealthSettingsModel: ObservableObject {
    @Published private(set) var health: [ModuleID: ModuleHealth] = [:]
    @Published private(set) var observationFailed: Set<ModuleID> = []
    @Published private(set) var requests: Set<ModuleID> = []
    @Published private(set) var responses: [ModuleID: ModuleRecoveryResponse] = [:]
    let entries: [ModuleRegistration]
    private var subscriptions: [ModuleID: Task<Void, Never>] = [:]
    private var actions: [ModuleID: Task<Void, Never>] = [:]
    private var lifetime = UUID()
    private let remote: FeatureModuleHealth?
    private var remoteUpdates: Task<Void, Never>?
    private(set) var observing = false

    var affectedEntries: [ModuleRegistration] {
        entries.filter { entry in
            guard !observationFailed.contains(entry.id) else { return false }
            guard let snapshot = health[entry.id] else { return false }
            return snapshot.failure == .quarantined || snapshot.failure == .healthPersistence
                || snapshot.state == .degraded || snapshot.state == .circuitOpen || snapshot.state == .recovering
        }
    }

    var unavailableCount: Int {
        let unavailable = affectedEntries.filter { entry in
            guard let snapshot = health[entry.id] else { return false }
            return snapshot.failure == .quarantined || snapshot.failure == .healthPersistence
                || snapshot.state == .degraded
        }
        return Set(unavailable.map { featureKey($0.id) }).count
    }

    var affectedFeatureCount: Int {
        Set(affectedEntries.map { featureKey($0.id) }).count
    }

    var summaryKey: String {
        if entries.isEmpty { return "settings.services.summaryUnknown" }
        if unavailableCount > 0 { return "settings.services.summaryUnavailable" }
        if !observationFailed.isEmpty { return "settings.services.summaryUnknown" }
        if !affectedEntries.isEmpty { return "settings.services.summaryRecovering" }
        return "settings.services.summaryHealthy"
    }

    func canOfferRetry(_ id: ModuleID) -> Bool {
        guard canRecover(id), let snapshot = health[id] else { return false }
        guard snapshot.failure != .invalidPolicy else { return false }
        let paused = snapshot.failure == .quarantined || snapshot.failure == .healthPersistence
            || snapshot.state == .degraded
        return paused && snapshot.state != .circuitOpen && snapshot.state != .recovering
            && snapshot.activeOperations == 0 && !snapshot.hasLifecycleWork
    }

    func detailKey(_ id: ModuleID) -> String {
        guard let snapshot = health[id] else { return "settings.services.summaryUnknownDetail" }
        if snapshot.failure == .invalidPolicy { return "settings.services.invalidPolicyDetail" }
        if snapshot.failure == .quarantined { return "settings.services.quarantinedDetail" }
        if snapshot.failure == .healthPersistence { return "settings.services.healthPersistenceDetail" }
        if snapshot.activeOperations > 0 || snapshot.hasLifecycleWork { return "settings.services.busy" }
        switch snapshot.state {
        case .degraded: return "settings.services.unavailableDetail"
        case .circuitOpen: return "settings.services.coolingDownDetail"
        case .recovering, .starting: return "settings.services.recoveringDetail"
        case .stopped, .ready, .disabled: return "settings.services.summaryHealthyDetail"
        }
    }

    func featureKey(_ id: ModuleID) -> String {
        switch id {
        case .conversations: "settings.services.conversations"
        case .wordBook: "settings.services.wordBook"
        case .notebook: "settings.services.notebook"
        case .mediaExtraction, .mediaPreviews: "settings.services.featureAttachments"
        case .clipboardThumbnails, .clipboardOCR, .clipboardMetadata, .mediaPlayback: "settings.services.featureClipboard"
        case .frameRegistration, .textRecognition: "settings.services.featureScreenshots"
        case .recordingTimeline, .recordingExport: "settings.services.featureRecordings"
        case .nativeSystem: "settings.services.featureCommands"
        case .whisperInference: "settings.services.featureTranscription"
        case .fileIndex, .semanticValidation, .semanticIndexReading, .semanticPriorityReading,
             .semanticQueryInference, .semanticIndexInference, .semanticMediaInference: "settings.services.featureFileSearch"
        }
    }

    init(registry: ModuleRegistry?, remote: FeatureModuleHealth? = FeatureProcess.enabled && FeatureProcess.owns(.settings) ? FeatureModuleHealth() : nil) {
        self.remote = remote
        var seen: Set<ModuleID> = []
        if let remote {
            entries = ModuleID.allCases.map { id in
                ModuleRegistration(presentation: id, recover: { await remote.recover(id, reset: $0) })
            }
        } else { entries = (registry?.registrations ?? []).filter { seen.insert($0.id).inserted } }
    }

    deinit {
        remoteUpdates?.cancel()
        for task in subscriptions.values { task.cancel() }
        for task in actions.values { task.cancel() }
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        let current = lifetime
        if let remote {
            remoteUpdates = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let snapshots = try await remote.snapshots()
                        self?.publishRemote(snapshots, lifetime: current)
                    } catch { self?.remoteUnavailable(lifetime: current) }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        health.removeAll()
        observationFailed.removeAll()
        for entry in entries {
            if let snapshot = entry.health.current { health[entry.id] = snapshot }
            do {
                let stream = try entry.health.observe()
                subscriptions[entry.id] = Task { [weak self] in
                    for await snapshot in stream {
                        guard !Task.isCancelled, let self, self.lifetime == current else { return }
                        self.receive(snapshot, for: entry.id)
                    }
                }
            } catch { observationFailed.insert(entry.id) }
        }
    }

    private func publishRemote(_ snapshots: [ModuleID: ModuleHealth], lifetime: UUID) {
        guard observing, self.lifetime == lifetime else { return }
        observationFailed.removeAll()
        for entry in entries {
            entry.health.publish(snapshots[entry.id] ?? .init(state: .stopped, generation: UUID(),
                pendingStarts: 0, activeOperations: 0, hasLifecycleWork: false, failure: nil))
        }
    }

    private func remoteUnavailable(lifetime: UUID) {
        guard observing, self.lifetime == lifetime else { return }
        observationFailed = Set(entries.map(\.id))
    }

    func stopObserving() {
        remoteUpdates?.cancel(); remoteUpdates = nil
        observing = false
        lifetime = UUID()
        for task in subscriptions.values { task.cancel() }
        for task in actions.values { task.cancel() }
        subscriptions.removeAll()
        actions.removeAll()
        requests.removeAll()
        responses.removeAll()
    }

    func canRecover(_ id: ModuleID) -> Bool {
        guard observing, !observationFailed.contains(id), !requests.contains(id), let health = health[id] else { return false }
        return health.state != .ready && health.state != .disabled && health.state != .starting
    }

    func recover(_ id: ModuleID) {
        guard canRecover(id), let entry = entries.first(where: { $0.id == id }) else { return }
        let reset = health[id]?.failure == .quarantined || health[id]?.failure == .healthPersistence
        let current = lifetime
        requests.insert(id)
        responses[id] = nil
        actions[id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let response = await entry.recover(reset)
            guard !Task.isCancelled, let self, self.lifetime == current else { return }
            self.requests.remove(id)
            self.actions[id] = nil
            if let snapshot = entry.health.current { self.receive(snapshot, for: id) }
            if self.health[id]?.state != .ready { self.responses[id] = response }
        }
    }

    private func receive(_ snapshot: ModuleHealth, for id: ModuleID) {
        health[id] = snapshot
        if snapshot.state == .ready || snapshot.state == .starting { responses[id] = nil }
    }

    func statusKey(_ id: ModuleID) -> String {
        if observationFailed.contains(id) { return "settings.services.observationFailed" }
        guard let value = health[id] else { return "settings.services.stopped" }
        if value.state == .disabled { return "settings.services.disabled" }
        if value.state == .starting { return "settings.services.recovering" }
        if value.failure == .quarantined { return "settings.services.quarantined" }
        if value.failure == .healthPersistence { return "settings.services.unavailable" }
        switch value.state {
        case .stopped: return "settings.services.stopped"
        case .starting, .recovering: return "settings.services.recovering"
        case .ready: return "settings.services.ready"
        case .circuitOpen: return "settings.services.coolingDown"
        case .degraded: return "settings.services.unavailable"
        case .disabled: return "settings.services.disabled"
        }
    }

    func responseKey(_ id: ModuleID) -> String? {
        guard let response = responses[id] else { return nil }
        switch response {
        case .started:
            return health[id]?.state == .degraded ? "settings.services.unavailable" : "settings.services.requested"
        case .coolingDown: return "settings.services.wait"
        case .busy: return "settings.services.busy"
        case .disabled: return "settings.services.disabled"
        case .unavailable: return "settings.services.unavailable"
        case .cancelled, .ready: return nil
        }
    }
}
