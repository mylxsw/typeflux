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
    private(set) var observing = false

    init(registry: ModuleRegistry?) {
        var seen: Set<ModuleID> = []
        entries = (registry?.registrations ?? []).filter { seen.insert($0.id).inserted }
    }

    deinit {
        for task in subscriptions.values { task.cancel() }
        for task in actions.values { task.cancel() }
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        let current = lifetime
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

    func stopObserving() {
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
