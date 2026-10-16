import Foundation

/// Adapts one existing disposable extraction pool. Typed requests stay in the
/// pool; the supervisor manages readiness and recovery, never request replay.
final class MediaExtractionModule: @unchecked Sendable {
    enum Domain: String, CaseIterable, Sendable {
        case mediaExtraction, mediaPreviews, clipboardThumbnails, frameRegistration, textRecognition, clipboardOCR, clipboardMetadata, recordingTimeline, recordingExport
        var id: ModuleID {
            switch self {
            case .mediaExtraction: .mediaExtraction
            case .mediaPreviews: .mediaPreviews
            case .clipboardThumbnails: .clipboardThumbnails
            case .frameRegistration: .frameRegistration
            case .textRecognition: .textRecognition
            case .clipboardOCR: .clipboardOCR
            case .clipboardMetadata: .clipboardMetadata
            case .recordingTimeline: .recordingTimeline
            case .recordingExport: .recordingExport
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
            case .clipboardMetadata: .clipboardMetadata
            case .recordingTimeline: .recordingTimeline
            case .recordingExport: .recordingExport
            }
        }
    }
    let module: ModuleHandle<MediaWorker>
    private let domain: Domain
    private let worker: MediaWorker
    private let gate: ModuleWorkerGate
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
        let gate = ModuleWorkerGate(admission: module.supervisor.admission, health: module.health, store: store)
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
