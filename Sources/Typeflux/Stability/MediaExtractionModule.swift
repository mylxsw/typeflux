import Foundation

/// Adapts one existing disposable extraction pool. Typed requests stay in the
/// pool; the supervisor manages readiness and recovery, never request replay.
final class MediaExtractionModule: @unchecked Sendable {
    enum Domain: String, CaseIterable, Sendable {
        case mediaExtraction, mediaPreviews, clipboardThumbnails, frameRegistration, textRecognition, clipboardOCR
        var id: ModuleID {
            switch self {
            case .mediaExtraction: .mediaExtraction
            case .mediaPreviews: .mediaPreviews
            case .clipboardThumbnails: .clipboardThumbnails
            case .frameRegistration: .frameRegistration
            case .textRecognition: .textRecognition
            case .clipboardOCR: .clipboardOCR
            }
        }
        var worker: MediaWorker {
            switch self {
            case .mediaExtraction: .shared
            case .mediaPreviews: .previews
            case .clipboardThumbnails: .clipboardThumbnails
            case .frameRegistration: .frameRegistration
            case .textRecognition: .textRecognition
            case .clipboardOCR: .clipboardOCR
            }
        }
    }
    let module: ModuleHandle<MediaWorker>
    private let domain: Domain
    private let worker: MediaWorker
    private let gate: MediaExtractionGate
    private let observation: Task<Void, Never>

    init(worker: MediaWorker, healthDirectory: URL, domain: Domain = .mediaExtraction, policy: ModulePolicy = .init(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.worker = worker; self.domain = domain
        let store = ModuleHealthStore(url: healthDirectory.appendingPathComponent(domain.rawValue + ".json"), uptime: uptime)
        let module = ModuleHandle<MediaWorker>(policy: policy, healthStore: store,
            factory: { try worker.checkReadiness(); return worker },
            cleanup: { await $0.retireManaged() }, classify: { _ in .waitForExplicitRetry },
            externalOperations: { worker.activeCount }, uptime: uptime)
        self.module = module
        let gate = MediaExtractionGate(admission: module.supervisor.admission, health: module.health, store: store)
        self.gate = gate
        if !worker.bind(gate) { module.preventNewWork() }
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
        gate.finish()
        observation.cancel()
        module.preventNewWork()
    }
}

/// No payloads, tasks per request, or disk I/O in the synchronous admission path.
/// The latest signal cannot lose a fault: the fault token is retained separately.
final class MediaExtractionGate: @unchecked Sendable {
    let admission: ModuleAdmission
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let health: ModuleHealthChannel
    private let store: ModuleHealthStore
    private let lock = NSLock()
    private var fault: UUID?
    private var disposition: ModuleFailureDisposition = .recover

    init(admission: ModuleAdmission, health: ModuleHealthChannel, store: ModuleHealthStore) {
        self.admission = admission; self.health = health; self.store = store
        (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var failure: (UUID?, ModuleFailureDisposition) { lock.withLock { (fault, disposition) } }
    func changed() { continuation.yield(()) }
    func finish() { continuation.finish() }

    func admit() throws -> UUID {
        guard admission.permitsWork, let snapshot = health.current, snapshot.state == .ready,
              lock.withLock({ fault != snapshot.generation }) else { throw ModuleFailure.unavailable }
        return snapshot.generation
    }

    func permits(_ generation: UUID?) -> Bool {
        guard let generation, let current = try? admit() else { return false }
        return current == generation
    }

    func failed(_ generation: UUID?, configuration: Bool) {
        guard let generation, permits(generation) else { return }
        lock.withLock {
            fault = generation; disposition = configuration ? .waitForExplicitRetry : .recover
            store.failed()
        }
        changed()
    }

    func succeeded(_ generation: UUID?) {
        guard let generation, admission.permitsWork, health.current?.generation == generation else { return }
        lock.withLock { if fault != generation { store.succeeded() } }
    }
}

/// The managed pools are composed without initializing audio, AppKit or storage.
/// Keep the adapters alive together; registrations alone do not own gate observers.
struct MediaExtractionModules: Sendable {
    let adapters: [MediaExtractionModule]
    var registrations: [ModuleRegistration] { adapters.map(\.registration) }

    init(healthDirectory: URL,
         worker: (MediaExtractionModule.Domain) -> MediaWorker = { $0.worker }) {
        adapters = MediaExtractionModule.Domain.allCases.map { domain in
            MediaExtractionModule(worker: worker(domain), healthDirectory: healthDirectory, domain: domain)
        }
    }
}
