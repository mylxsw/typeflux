import Foundation

/// Lifecycle only. Typed reads keep their stream/idle deadlines and privacy scopes.
final class SemanticReaderModule: @unchecked Sendable {
    enum Domain: CaseIterable {
        case validation, indexing, priority
        var id: ModuleID {
            switch self {
            case .validation: .semanticValidation
            case .indexing: .semanticIndexReading
            case .priority: .semanticPriorityReading
            }
        }
        func lane(in readers: SemanticFileReaders) -> SemanticFileReaderLane {
            switch self {
            case .validation: readers.validation
            case .indexing: readers.indexing
            case .priority: readers.priority
            }
        }
    }
    let module: ModuleHandle<SemanticFileReaderLane>
    let domain: Domain
    private let lane: SemanticFileReaderLane
    private let gate: ModuleWorkerGate
    private let ownsLane: Bool
    private let observation: Task<Void, Never>

    init(domain: Domain, lane: SemanticFileReaderLane, healthDirectory: URL,
         executable: URL = AskFileReader.executableURL, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.domain = domain; self.lane = lane
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent(domain.id.rawValue + ".json"), uptime: uptime)
        let module = ModuleHandle<SemanticFileReaderLane>(policy: policy, healthStore: store,
            factory: {
                let available = await Task.detached(priority: .utility) {
                    FileManager.default.isExecutableFile(atPath: executable.path)
                }.value
                guard available, !lane.isOccupied else { throw ModuleFailure.unavailable }
                return lane
            }, cleanup: { await $0.retireManaged() }, classify: { _ in .waitForExplicitRetry },
            externalOperations: { lane.isOccupied ? 1 : 0 }, uptime: uptime)
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
        if ownsLane { lane.ownership.stopOwned(); lane.stop() }
        gate.finish(); observation.cancel()
    }
}

final class SemanticReaderModules {
    let modules: [SemanticReaderModule]
    var registrations: [ModuleRegistration] { modules.map(\.registration) }
    init(readers: SemanticFileReaders, healthDirectory: URL) {
        modules = SemanticReaderModule.Domain.allCases.map {
            SemanticReaderModule(domain: $0, lane: $0.lane(in: readers), healthDirectory: healthDirectory)
        }
    }
}
