import Combine

/// GUL-636 integration slot; owned by the speech page task after foundation merges.
@MainActor
final class OnboardingSpeechModel: ObservableObject {
    weak var session: OnboardingViewModel?

    init(session: OnboardingViewModel) { self.session = session }

    @Published var canContinue: Bool? = nil
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?
}
