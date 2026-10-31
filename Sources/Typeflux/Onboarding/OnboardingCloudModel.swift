import Combine
import Foundation

/// Owns inline authentication; navigation remains an explicit footer action.
@MainActor
final class OnboardingCloudModel: ObservableObject {
    /// URL routing borrows the currently presented transaction without extending its lifetime.
    private(set) weak static var activeLogin: WebLoginCoordinator?
    private(set) weak static var activeSession: OnboardingViewModel?
    weak var session: OnboardingViewModel?
    let login: WebLoginCoordinator
    @Published var canContinue: Bool? = false
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?
    @Published private(set) var phase: WebLoginCoordinator.Phase = .idle
    @Published private(set) var entitlementReady = false
    @Published private(set) var error: String?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var localReady = false
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var revision = UUID()
    private var entitlementGeneration: Int?
    private var active: Bool

    init(session: OnboardingViewModel, login: WebLoginCoordinator? = nil) {
        self.session = session
        active = session.currentStep == .cloud
        self.login = login ?? session.authState.makeWebLoginCoordinator()
        self.login.$phase.sink { [weak self] phase in
            guard let self else { return }
            self.phase = phase
            // Another login entry can finish before this browser transaction ends.
            if signedIn {
                refresh()
            }
            updateReadiness()
        }.store(in: &subscriptions)
        session.authState.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.updateReadiness() }
        }.store(in: &subscriptions)
        session.$setupRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateReadiness() }
        }.store(in: &subscriptions)
        session.authState.$isLoggedIn.dropFirst().sink { [weak self] signedIn in
            if signedIn {
                Task { @MainActor [weak self] in self?.refresh() }
                return
            }
            guard let self else { return }
            let keepPageActive = active
            entitlementReady = false
            entitlementGeneration = nil
            deactivate()
            active = keepPageActive
        }.store(in: &subscriptions)
        session.$currentStep.dropFirst().sink { [weak self] step in
            if step == .cloud {
                self?.active = true
            } else {
                self?.deactivate()
            }
        }.store(in: &subscriptions)
        Self.activeSession = session
    }

    deinit {
        refreshTask?.cancel()
        downloadTask?.cancel()
    }

    var signedIn: Bool {
        session?.authState.isLoggedIn == true && ![.creating, .waiting, .exchanging].contains(phase)
    }

    var cloudSpeech: Bool {
        entitlementReady && entitlementGeneration == session?.authState.sessionGeneration
            && session?.authState.canUseCloudASR == true
    }

    var profile: UserProfile? {
        session?.authState.userProfile
    }

    var planName: String {
        guard let snapshot = session?.authState.subscription else { return "" }
        return snapshot.planName ?? snapshot.planCode?.capitalized ?? L("auth.account.subscriptionNoPlan")
    }

    func activate() {
        guard session?.currentStep == .cloud, !Task.isCancelled else { return }
        active = true
        refresh()
    }

    func start() async {
        guard active, !signedIn, session?.currentStep == .cloud else { return }
        error = nil
        guard login.configuration.enabled else {
            phase = .failed(.restartRequired)
            updateReadiness()
            return
        }
        session?.authState.webLoginCoordinator.cancel()
        Self.activeLogin = login
        await login.start()
    }

    func reopen() {
        login.reopen()
    }

    func cancel() {
        login.cancel()
    }

    func switchAccount() async {
        guard active, session?.currentStep == .cloud else { return }
        deactivate()
        session?.authState.logout(clearRecentInputMemory: false)
        active = true
        await start()
    }

    func refresh() {
        guard active, signedIn, refreshTask == nil, let session else { updateReadiness(); return }
        let id = revision
        let generation = session.authState.sessionGeneration
        entitlementReady = false
        error = nil
        isBusy = true
        refreshTask = Task { [weak self, weak session] in
            guard let session else { return }
            // AuthState coalesces an in-flight refresh by returning its cached snapshot.
            // Wait for that load before requesting an authoritative result for this page.
            while session.authState.isLoadingSubscription {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let snapshot = await session.authState.refreshSubscription()
            guard let self, !Task.isCancelled, revision == id else { return }
            guard session.authState.sessionGeneration == generation else {
                refreshTask = nil
                updateReadiness()
                return
            }
            entitlementReady = snapshot != nil && !session.authState.isLoadingSubscription
            entitlementGeneration = entitlementReady ? generation : nil
            // A download may have failed while this request was suspended.
            if !entitlementReady {
                error = L("setup.cloud.checkFailed")
            }
            refreshTask = nil
            updateReadiness()
        }
    }

    func retry() {
        if entitlementReady, !cloudSpeech, !localReady {
            downloadLocalModel()
        } else {
            refresh()
        }
    }

    func downloadLocalModel() {
        guard active, downloadTask == nil, let session, let manager = session.localModelManager else { return }
        let model = LocalSTTModel.senseVoiceSmall
        let configuration = LocalSTTConfiguration(model: model, modelIdentifier: model.defaultModelIdentifier,
                                                  downloadSource: session.settingsStore.localSTTDownloadSource,
                                                  autoSetup: true)
        let id = revision
        let generation = session.authState.sessionGeneration
        error = nil
        downloadProgress = 0
        updateReadiness()
        downloadTask = Task { [weak self, weak session] in
            defer {
                if let self, revision == id {
                    downloadProgress = nil
                    downloadTask = nil
                    updateReadiness()
                }
            }
            do {
                try await manager.prepareModel(configuration: configuration) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, revision == id, downloadTask != nil else { return }
                        downloadProgress = min(1, max(0, update.progress))
                    }
                }
                guard let self, let session, !Task.isCancelled, revision == id,
                      session.authState.sessionGeneration == generation else { return }
                if manager.isModelAvailable(model) {
                    session.settingsStore.localSTTModel = model
                    session.settingsStore.localSTTModelIdentifier = configuration.modelIdentifier
                    session.settingsStore.sttProvider = .localModel
                }
            } catch {
                guard let self, !Task.isCancelled, revision == id,
                      session?.authState.sessionGeneration == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func endSession() {
        deactivate()
        if Self.activeSession === session {
            Self.activeSession = nil
        }
    }

    func deactivate() {
        if Self.activeLogin === login {
            Self.activeLogin = nil
        }
        active = false
        revision = UUID()
        refreshTask?.cancel(); refreshTask = nil
        downloadTask?.cancel(); downloadTask = nil
        downloadProgress = nil
        if login.isBusy {
            login.cancel()
        }
        updateReadiness()
    }

    func updateReadiness() {
        guard let session else { canContinue = false; isBusy = false; return }
        if active, signedIn, session.authState.subscriptionError != nil, refreshTask == nil, error == nil {
            entitlementReady = false
            error = L("setup.cloud.checkFailed")
        }
        localReady = session.settingsStore.sttProvider == .localModel
            && session.localModelManager?.isModelAvailable(session.settingsStore.localSTTModel) == true
        isBusy = active && ([.creating, .waiting, .exchanging].contains(phase) || refreshTask != nil
            || downloadProgress != nil || (signedIn && session.authState.isLoadingSubscription))
        canContinue = active && signedIn && entitlementGeneration == session.authState
            .sessionGeneration && entitlementReady && !session.authState.isLoadingSubscription
            && session.authState.subscriptionError == nil && error == nil && (cloudSpeech || localReady)
        objectWillChange.send()
    }
}
