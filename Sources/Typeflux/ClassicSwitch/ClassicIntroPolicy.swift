import Foundation

/// Links shared by every Typeflux Classic entry point.
enum ClassicProductLinks {
    /// Website page that compares Typeflux with Typeflux Classic.
    static let comparisonURL = URL(string: "https://typeflux.app/classic")!
}

/// What the one-time Typeflux Classic introduction should do on this launch.
enum ClassicIntroDecision: Equatable {
    /// Fresh installs never see the introduction.
    case notEligible
    case alreadyShown
    case show
    /// The introduction waits until this launch's onboarding window closes.
    case showAfterOnboarding
}

enum ClassicIntroPolicy {
    /// `onboardingCompletedBeforeLaunch` is the raw `onboarding.completed` flag read before this
    /// launch could change it; `needsOnboarding` reports whether this launch presents onboarding.
    static func decide(
        onboardingCompletedBeforeLaunch: Bool,
        shownVersion: String?,
        isIneligible: Bool,
        needsOnboarding: Bool
    ) -> ClassicIntroDecision {
        if shownVersion != nil { return .alreadyShown }
        if isIneligible || !onboardingCompletedBeforeLaunch { return .notEligible }
        return needsOnboarding ? .showAfterOnboarding : .show
    }
}

/// UserDefaults state behind the introduction. Fresh installs are recorded as ineligible so the
/// introduction does not appear on a later launch, after their own onboarding has completed.
struct ClassicIntroStore {
    static let shownVersionKey = "classic.intro.shownVersion"
    static let ineligibleKey = "classic.intro.ineligible"
    static let onboardingCompletedKey = "onboarding.completed"

    let defaults: UserDefaults

    var onboardingCompleted: Bool { defaults.bool(forKey: Self.onboardingCompletedKey) }
    var shownVersion: String? { defaults.string(forKey: Self.shownVersionKey) }
    var isIneligible: Bool { defaults.bool(forKey: Self.ineligibleKey) }

    func markShown(version: String) {
        defaults.set(version, forKey: Self.shownVersionKey)
    }

    func markIneligible() {
        defaults.set(true, forKey: Self.ineligibleKey)
    }
}

/// Sequences the introduction after onboarding and after Classic availability is known.
/// The introduction is only shown while a published Classic can be switched to; otherwise it
/// stays pending (nothing is written) and is evaluated again on the next launch.
@MainActor
final class ClassicIntroCoordinator {
    private let store: ClassicIntroStore
    private let currentVersion: String
    private let isClassicAvailable: @MainActor () async -> Bool
    private let present: @MainActor () -> Void
    private var waitingForOnboarding = false
    private var evaluation: Task<Void, Never>?
    private(set) var hasPresented = false

    init(
        store: ClassicIntroStore,
        currentVersion: String,
        isClassicAvailable: @escaping @MainActor () async -> Bool,
        present: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.currentVersion = currentVersion
        self.isClassicAvailable = isClassicAvailable
        self.present = present
    }

    @discardableResult
    func launch(onboardingCompletedBeforeLaunch: Bool, needsOnboarding: Bool) -> ClassicIntroDecision {
        let decision = ClassicIntroPolicy.decide(
            onboardingCompletedBeforeLaunch: onboardingCompletedBeforeLaunch,
            shownVersion: store.shownVersion,
            isIneligible: store.isIneligible,
            needsOnboarding: needsOnboarding
        )
        switch decision {
        case .notEligible:
            if !store.isIneligible { store.markIneligible() }
        case .alreadyShown:
            break
        case .show:
            evaluate()
        case .showAfterOnboarding:
            waitingForOnboarding = true
        }
        return decision
    }

    func onboardingDidFinish() {
        guard waitingForOnboarding else { return }
        waitingForOnboarding = false
        evaluate()
    }

    /// Awaits the pending availability check; used by tests.
    func waitForEvaluation() async {
        await evaluation?.value
    }

    private func evaluate() {
        guard !hasPresented, evaluation == nil else { return }
        evaluation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.evaluation = nil }
            guard await self.isClassicAvailable(), !self.hasPresented, self.store.shownVersion == nil else { return }
            self.hasPresented = true
            self.store.markShown(version: self.currentVersion)
            self.present()
        }
    }
}
