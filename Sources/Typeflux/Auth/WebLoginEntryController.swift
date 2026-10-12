import Combine
import Foundation

/// Routes every login entry without presenting an intermediate native window.
@MainActor
final class WebLoginEntryController {
    private let coordinator: WebLoginCoordinator
    private let showNative: () -> Void
    private let reportFailure: (WebLoginFailure) -> Void
    private var observation: AnyCancellable?
    private var reportedFailure = false

    init(coordinator: WebLoginCoordinator, showNative: @escaping () -> Void,
         reportFailure: @escaping (WebLoginFailure) -> Void) {
        self.coordinator = coordinator
        self.showNative = showNative
        self.reportFailure = reportFailure
        observation = coordinator.$phase.sink { [weak self, weak coordinator] phase in
            // Published values arrive before the property is updated.
            Task { @MainActor [weak self] in
                guard let self, coordinator?.phase == phase else { return }
                if case .failed = phase { showCurrentFailure() }
                else { reportedFailure = false }
            }
        }
    }

    func show() {
        guard coordinator.configuration.enabled else { showNative(); return }
        if coordinator.phase == .waiting { coordinator.reopen(); return }
        guard !coordinator.isBusy else { return }
        reportedFailure = false
        Task { await coordinator.start() }
    }

    func showCurrentFailure() {
        guard case let .failed(failure) = coordinator.phase, !reportedFailure else { return }
        reportedFailure = true
        reportFailure(failure)
    }
}
