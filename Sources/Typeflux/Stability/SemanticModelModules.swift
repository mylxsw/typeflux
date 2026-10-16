import Foundation

/// Capability only; never loads models, launches a probe or repeats inference.
final class SemanticModelModule: @unchecked Sendable {
    enum Domain: CaseIterable {
        case query, indexing, media
        var id: ModuleID {
            switch self {
            case .query: .semanticQueryInference
            case .indexing: .semanticIndexInference
            case .media: .semanticMediaInference
            }
        }
        func lane(in readers: SemanticEmbeddingOwners) -> SemanticEmbeddingOwnership {
            switch self {
            case .query: readers.query
            case .indexing: readers.indexing
            case .media: readers.media
            }
        }
    }
    let module: ModuleHandle<SemanticEmbeddingOwnership>
    let domain: Domain
    private let lane: SemanticEmbeddingOwnership
    private let gate: ModuleWorkerGate
    private let ownsLane: Bool
    private let observation: Task<Void, Never>

    init(domain: Domain, lane: SemanticEmbeddingOwnership, healthDirectory: URL,
         executable: URL? = nil, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.domain = domain; self.lane = lane
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent(domain.id.rawValue + ".json"), uptime: uptime)
        let module = ModuleHandle<SemanticEmbeddingOwnership>(policy: policy, healthStore: store,
            factory: {
                let available = await Task.detached(priority: .utility) {
                    FileManager.default.isExecutableFile(atPath: (executable ?? SemanticModel.helperURL).path)
                }.value
                guard available, lane.isIdle else { throw ModuleFailure.unavailable }
                return lane
            }, cleanup: { await $0.retireManaged() }, classify: { _ in .waitForExplicitRetry },
            externalOperations: { lane.isIdle ? 0 : 1 }, uptime: uptime)
        self.module = module
        let gate = ModuleWorkerGate(admission: module.supervisor.admission, health: module.health, store: store)
        self.gate = gate; ownsLane = lane.bind(gate)
        if !ownsLane { module.preventNewWork() }
        observation = Task { [supervisor = module.supervisor, gate] in
            for await _ in gate.events {
                guard !Task.isCancelled else { return }
                let failure = gate.failure
                await supervisor.externalActivity(failedGeneration: failure.0, disposition: failure.1)
            }
        }
    }
    var registration: ModuleRegistration { .init(domain.id, handle: module) }
    deinit {
        module.preventNewWork()
        if ownsLane { lane.native.stopOwned() }
        gate.finish(); observation.cancel()
    }
}

final class SemanticModelModules {
    let modules: [SemanticModelModule]
    var registrations: [ModuleRegistration] { modules.map(\.registration) }
    init(readers: SemanticEmbeddingOwners, healthDirectory: URL, executable: URL? = nil) {
        modules = SemanticModelModule.Domain.allCases.map {
            SemanticModelModule(domain: $0, lane: $0.lane(in: readers), healthDirectory: healthDirectory, executable: executable)
        }
    }
}
