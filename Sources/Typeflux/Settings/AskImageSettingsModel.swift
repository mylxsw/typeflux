import SwiftUI

@MainActor
final class AskImageSettingsModel: ObservableObject {
    @Published var configuration = AskImageConfiguration()
    @Published var key = ""
    @Published private(set) var enabled = false
    @Published var models: [String] = []
    @Published var loading = false
    @Published var notice: String?
    @Published private(set) var noticeIsError = false
    private var savedConfiguration = AskImageConfiguration()
    private var savedKey = ""
    let store: AskImageSettings
    private let discover: (AskImageConfiguration, String) async throws -> [String]
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(store: AskImageSettings, discover: @escaping (AskImageConfiguration, String) async throws -> [String] = {
        try await AskImageModelDiscovery().models(configuration: $0, key: $1)
    }) {
        self.store = store; self.discover = discover
        enabled = store.enabled
        select(store.provider)
    }

    func select(_ provider: AskImageProvider) {
        cancelDiscovery()
        configuration = store.configuration(for: provider)
        key = store.key(for: configuration)
        savedConfiguration = configuration; savedKey = key
        models = provider.suggestedModels
        clearNotice()
    }

    func setEndpoint(_ value: String) {
        guard value != configuration.baseURL else { return }
        configuration.baseURL = value
        endpointChanged()
    }

    func endpointChanged() {
        cancelDiscovery()
        key = store.key(for: configuration)
        models = configuration.provider.suggestedModels
        clearNotice()
    }

    var hasChanges: Bool {
        configuration != savedConfiguration || key != savedKey || configuration.provider != store.provider
    }

    var status: AgentCapabilityStatus {
        var inputs = AgentCapabilityInputs()
        inputs.imageGenerationEnabled = enabled
        inputs.imageGenerationReady = store.isReady
        return AgentCapabilityStatus.status(of: .imageGeneration, inputs: inputs)
    }

    /// Capability switches take effect immediately, independently of connection drafts.
    func setEnabled(_ value: Bool) {
        enabled = value
        store.enabled = value
    }

    func clearNotice() {
        notice = nil
        noticeIsError = false
    }

    func save() {
        do {
            if enabled {
                try configuration.validate(key: key)
            }
            try store.save(configuration, key: key)
            savedConfiguration = configuration; savedKey = key
            noticeIsError = false
            notice = L("imagegen.saved")
        } catch {
            noticeIsError = true
            notice = error.localizedDescription
        }
    }

    func refresh() {
        cancelDiscovery()
        let snapshot = configuration, secret = key, id = generation
        loading = true; clearNotice()
        task = Task {
            defer {
                if generation == id {
                    loading = false; task = nil
                }
            }
            do {
                let found = try await discover(snapshot, secret)
                guard !Task.isCancelled, generation == id, configuration == snapshot, key == secret else { return }
                models = Array(Set(found + snapshot.provider.suggestedModels)).sorted {
                    let lhs = AskImageModelDiscovery.imageLike($0), rhs = AskImageModelDiscovery.imageLike($1)
                    return lhs == rhs ? $0 < $1 : lhs
                }
                notice = L("imagegen.models.loaded", found.count)
            } catch {
                guard !Task.isCancelled, generation == id, configuration == snapshot, key == secret else { return }
                noticeIsError = true
                notice = L("imagegen.models.failed")
            }
        }
    }

    func cancelDiscovery() {
        generation = UUID(); task?.cancel(); task = nil; loading = false
    }
}
