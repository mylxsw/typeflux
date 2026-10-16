import Foundation

/// Readiness restores worker admission only; it never scans or rebuilds the index.
final class FileIndexModule: @unchecked Sendable {
    let module: ModuleHandle<AskFileIndex>
    private let index: AskFileIndex
    private let gate: ModuleWorkerGate
    private let ownsIndex: Bool
    private let observation: Task<Void, Never>

    init(index: AskFileIndex, healthDirectory: URL, executable: URL = AskFileReader.executableURL, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.index = index
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent("fileIndex.json"), uptime: uptime)
        let module = ModuleHandle<AskFileIndex>(policy: policy, healthStore: store,
            factory: {
                let available = await Task.detached(priority: .utility) {
                    FileManager.default.isExecutableFile(atPath: executable.path)
                }.value
                guard available, !index.readerOwnership.isOccupied else { throw ModuleFailure.unavailable }
                return index
            }, cleanup: { await $0.retireWorker() },
            classify: { _ in .waitForExplicitRetry }, externalOperations: { index.readerOwnership.isOccupied ? 1 : 0 }, uptime: uptime)
        self.module = module
        let gate = ModuleWorkerGate(admission: module.supervisor.admission, health: module.health, store: store)
        self.gate = gate
        ownsIndex = index.readerOwnership.bind(gate) { [weak index] in index?.suspendWorker() }
        if !ownsIndex { module.preventNewWork() }
        observation = Task { [supervisor = module.supervisor, gate] in
            for await _ in gate.events {
                guard !Task.isCancelled else { return }
                let failure = gate.failure
                await supervisor.externalActivity(failedGeneration: failure.0, disposition: failure.1)
            }
        }
    }
    var registration: ModuleRegistration { .init(.fileIndex, handle: module) }
    deinit {
        module.preventNewWork()
        if ownsIndex { index.readerOwnership.stopOwned() }
        gate.finish(); observation.cancel()
    }
}
