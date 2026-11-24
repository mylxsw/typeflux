import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class CloudLoginSyncCoordinatorTests: XCTestCase {
    func testCaptureNativeCloudSwitchConfirmation() async throws {
        guard CloudSpeechAcceptanceCapture.enabled else { throw XCTSkip("Screenshot capture is opt-in") }
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        let auth = makeAuthState(subscription: activeSubscription())
        let app = NSApplication.shared
        let originalLanguage = AppLocalization.shared.language
        let originalPolicy = app.activationPolicy()
        let originalAppearance = app.appearance
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        // Match the host app so AppKit draws the active default button.
        XCTAssertTrue(app.setActivationPolicy(.accessory))
        app.appearance = NSAppearance(named: .darkAqua)
        defer {
            app.appearance = originalAppearance
            app.setActivationPolicy(originalPolicy)
            AppLocalization.shared.setLanguage(originalLanguage)
        }
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: auth)
        let activationDeadline = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let window = app.modalWindow, let content = window.contentView else { return }
                if !app.isActive || !window.isKeyWindow {
                    if Date() < activationDeadline { return }
                    timer.invalidate()
                    XCTFail("The confirmation did not become the active window")
                    app.stopModal(withCode: .alertSecondButtonReturn)
                    return
                }
                timer.invalidate()
                do {
                    let button = try XCTUnwrap(window.defaultButtonCell?.controlView as? NSButton)
                    XCTAssertEqual(button.title, L("cloud.subscriptionSwitch.confirm"))
                    XCTAssertEqual(button.keyEquivalent, "\r")
                    try CloudSpeechAcceptanceCapture.save(content.superview ?? content, name: "01-switch")
                    button.performClick(nil)
                } catch {
                    XCTFail("Could not capture the Cloud confirmation: \(error)")
                    app.stopModal(withCode: .alertSecondButtonReturn)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        await signIn(auth)
        for _ in 0..<30 where settings.sttProvider != .typefluxOfficial {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.rewriteModelReference, "cloud:default")
        withExtendedLifetime(coordinator) {}
    }

    func testPromptsAndAppliesCloudDefaultsAfterLoginWithExistingEntitlement() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.localOptimizationEnabled = true
        settingsStore.onboardingSpeechDeferred = true
        settingsStore.onboardingAIDeferred = true
        settingsStore.defaults.set("old-model", forKey: "ask.model.default")
        settingsStore.defaults.set("old-model", forKey: "llm.profile.reference")
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let authState = makeAuthState(subscription: activeSubscription())
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        await signIn(authState)

        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertFalse(settingsStore.localOptimizationEnabled)
        XCTAssertFalse(settingsStore.onboardingSpeechDeferred)
        XCTAssertFalse(settingsStore.onboardingAIDeferred)
        XCTAssertEqual(settingsStore.defaults.string(forKey: "ask.model.default"), "old-model")
        XCTAssertEqual(settingsStore.rewriteModelReference, "cloud:default")
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        XCTAssertEqual(prompt.confirmCallCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testConvenienceRefreshCannotTurnCloudVoiceAccessIntoARewriteOnlyOffer() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        settings.llmRemoteProvider = .openAI
        let allowed = BillingSubscriptionSnapshot(
            planCode: "free", status: "free", currentPeriodStart: nil, currentPeriodEnd: nil,
            cancelAtPeriodEnd: false, entitled: true, paid: false, cloudASRAllowed: true
        )
        let refreshStarted = expectation(description: "settings subscription refresh")
        let (finishRefresh, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        var requestCount = 0
        let state = makeAuthState { _ in
            requestCount += 1
            if requestCount == 2 {
                refreshStarted.fulfill()
                for await _ in finishRefresh { break }
            }
            return allowed
        }
        await signIn(state)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)

        let settingsRefresh = Task { await state.refreshSubscription() }
        await fulfillment(of: [refreshStarted], timeout: 2)
        XCTAssertTrue(state.isLoadingSubscription)
        XCTAssertFalse(state.canUseCloudASR)
        NotificationCenter.default.post(name: .authDidLogin, object: state)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(prompt.confirmCallCount, 0)

        release.finish()
        _ = await settingsRefresh.value
        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(prompt.cloudDefaultsConfirmCallCount, 1)
        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.llmRemoteProvider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }

    func testFailedSubscriptionCheckWaitsForRecoveryBeforeOfferingAChoice() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        settings.llmRemoteProvider = .openAI
        var failCheck = true
        let allowed = activeSubscription()
        let state = makeAuthState { _ in
            if failCheck { throw URLError(.notConnectedToInternet) }
            return allowed
        }
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)
        await signIn(state)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.confirmedCloudASRAccess)
        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(settings.sttProvider, .aliCloud)
        XCTAssertEqual(settings.llmRemoteProvider, .openAI)

        failCheck = false
        await state.refreshSubscription()
        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(prompt.cloudDefaultsConfirmCallCount, 1)
        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.llmRemoteProvider, .typefluxCloud)

        await state.refreshSubscription()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(prompt.confirmCallCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testReplacementLoginCannotUsePreviousAccountsVoiceAccess() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        settings.llmRemoteProvider = .openAI
        let allowed = activeSubscription()
        var replacementReady = false
        let state = makeAuthState { token in
            if token == "first" { return allowed }
            if !replacementReady { throw URLError(.timedOut) }
            return allowed
        }
        await signIn(state, token: "first")
        XCTAssertEqual(state.confirmedCloudASRAccess, true)
        state.subscriptionSyncGeneration = state.sessionGeneration
        state.isSyncingSubscription = true
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)

        await signIn(state, token: "second")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.confirmedCloudASRAccess)
        XCTAssertEqual(prompt.confirmCallCount, 0)

        replacementReady = true
        await state.refreshSubscription()
        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.llmRemoteProvider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }

    func testManualModelChangeSupersedesAWaitingLoginOffer() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        settings.llmRemoteProvider = .openAI
        let allowed = activeSubscription()
        var failCheck = true
        let state = makeAuthState { _ in
            if failCheck { throw URLError(.timedOut) }
            return allowed
        }
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)
        await signIn(state)

        settings.sttProvider = .localModel
        failCheck = false
        await state.refreshSubscription()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(settings.sttProvider, .localModel)
        XCTAssertEqual(settings.llmRemoteProvider, .openAI)
        withExtendedLifetime(coordinator) {}
    }

    func testSigningOutWhileConfirmingCannotSwitchModels() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        settings.llmRemoteProvider = .openAI
        let state = makeAuthState(subscription: activeSubscription())
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true) {
            state.logout(clearRecentInputMemory: false)
        }
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)

        await signIn(state)
        try await waitForPromptCount(1, in: prompt)

        XCTAssertFalse(state.isLoggedIn)
        XCTAssertEqual(settings.sttProvider, .aliCloud)
        XCTAssertEqual(settings.llmRemoteProvider, .openAI)
        withExtendedLifetime(coordinator) {}
    }

    func testPermissionRevokedWhileConfirmingDoesNotSwitchEitherModel() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        settings.llmRemoteProvider = .openAI
        let state = makeAuthState(subscription: activeSubscription())
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true) {
            state.subscription = .none
        }
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)

        await signIn(state)
        try await waitForPromptCount(1, in: prompt)
        await Task.yield()

        XCTAssertEqual(prompt.cloudDefaultsConfirmCallCount, 1)
        XCTAssertEqual(settings.sttProvider, .aliCloud)
        XCTAssertEqual(settings.llmRemoteProvider, .openAI)
        withExtendedLifetime(coordinator) {}
    }

    func testAccountWithoutCloudSpeechAccessDoesNotOfferPartialSwitch() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.onboardingSpeechDeferred = true
        settingsStore.onboardingAIDeferred = true
        settingsStore.defaults.set("old-model", forKey: "llm.profile.reference")
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let authState = makeAuthState(subscription: .none)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        await signIn(authState)

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(prompt.cloudDefaultsConfirmCallCount, 0)
        XCTAssertEqual(settingsStore.sttProvider, .whisperAPI)
        XCTAssertTrue(settingsStore.onboardingSpeechDeferred)
        XCTAssertTrue(settingsStore.onboardingAIDeferred)
        XCTAssertEqual(settingsStore.rewriteModelReference, "old-model")
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .openAI)
        withExtendedLifetime(coordinator) {}
    }

    func testPromptsAndAppliesCloudDefaultsAfterCheckoutSubscriptionEntitlement() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.llmProvider = .ollama
        settingsStore.llmRemoteProvider = .openAI

        let paid = activeSubscription()
        let authState = makeAuthState(syncSubscription: { _ in paid }) { _ in .none }
        await signIn(authState)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        authState.pendingCheckoutSubscriptionEntitlement = true
        _ = try await authState.syncSubscription()

        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        XCTAssertEqual(settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
        XCTAssertEqual(prompt.confirmCallCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testPostsModelDefaultsNotificationAfterApplyingCloudDefaults() async {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .localModel
        settingsStore.llmProvider = .ollama

        let authState = makeAuthState(subscription: activeSubscription())
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )
        let expectation = expectation(description: "cloud defaults notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .cloudAccountModelDefaultsDidApply,
            object: settingsStore,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        await signIn(authState)

        await fulfillment(of: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        withExtendedLifetime(coordinator) {}
    }

    func testKeepsCurrentProvidersWhenPromptDeclined() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let authState = makeAuthState(subscription: activeSubscription())
        await signIn(authState)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: false)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: authState)

        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(settingsStore.sttProvider, .whisperAPI)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .openAI)
        await authState.refreshSubscription()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(prompt.confirmCallCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testAppliesCloudDefaultsWhenOnlyOneProviderDiffers() async throws {
        let settingsStore = makeSettingsStore()
        // A scene-specific rewrite selection takes precedence over the legacy provider.
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud
        settingsStore.defaults.set("custom:previous", forKey: "llm.profile.reference")

        let authState = makeAuthState(subscription: activeSubscription())
        await signIn(authState)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: authState)

        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        XCTAssertEqual(settingsStore.rewriteModelReference, "cloud:default")
        withExtendedLifetime(coordinator) {}
    }

    func testSwitchingSpeechPreservesAnExistingCloudRewriteModel() async throws {
        let settings = makeSettingsStore()
        settings.sttProvider = .aliCloud
        let rewriteModel = AskCloudModel(id: "chosen-rewrite", name: "Chosen Rewrite", scenarios: ["rewrite"])
        settings.defaults.set(try JSONEncoder().encode([rewriteModel]), forKey: AskModelLibrary.rewriteCatalogKey)
        settings.defaults.set(rewriteModel.reference, forKey: "llm.profile.reference")
        let state = makeAuthState(subscription: activeSubscription())
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)

        await signIn(state)
        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(settings.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settings.rewriteModelReference, rewriteModel.reference)
        XCTAssertEqual(settings.textLLMConfiguration().provider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }

    func testStaysSilentWhenAlreadyFullyOnCloud() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud

        let authState = makeAuthState(subscription: activeSubscription())
        await signIn(authState)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: authState)

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }

    func testIgnoresUnrelatedNotifications() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.llmProvider = .ollama
        settingsStore.llmRemoteProvider = .openAI

        let authState = makeAuthState(subscription: activeSubscription())
        await signIn(authState)
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(
            settingsStore: settingsStore,
            authState: authState,
            promptPresenter: prompt
        )

        NotificationCenter.default.post(
            name: Notification.Name("SomeOtherNotification"),
            object: nil
        )
        await signIn(makeAuthState(subscription: activeSubscription()))

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(settingsStore.sttProvider, .whisperAPI)
        XCTAssertEqual(settingsStore.llmProvider, .ollama)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .openAI)
        withExtendedLifetime(coordinator) {}
    }

    // MARK: - Helpers

    func testOnboardingOwnsCloudSelectionWithoutAnotherModal() async throws {
        let settings = makeSettingsStore()
        settings.isOnboardingCompleted = false
        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let state = makeAuthState(subscription: activeSubscription())
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settings, authState: state, promptPresenter: prompt)

        await signIn(state)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(settings.sttProvider, .localModel)
        withExtendedLifetime(coordinator) {}
    }

    private func makeSettingsStore() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "CloudLoginSyncCoordinatorTests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.isOnboardingCompleted = true
        return settings
    }

    private func signIn(_ authState: AuthState, token: String = "token-1") async {
        await authState.handleLoginSuccess(token: token, expiresAt: Int(Date().timeIntervalSince1970) + 3600)
    }

    private func makeAuthState(subscription: BillingSubscriptionSnapshot) -> AuthState {
        makeAuthState { _ in subscription }
    }

    private func makeAuthState(
        syncSubscription: ((String) async throws -> BillingSubscriptionSnapshot)? = nil,
        fetchSubscription: @escaping (String) async throws -> BillingSubscriptionSnapshot
    ) -> AuthState {
        AuthState(
            loadStoredToken: { nil },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { _ in
                UserProfile(
                    id: UUID().uuidString,
                    email: "cloud-login-sync@test.com",
                    name: "Cloud Login Sync",
                    status: 1,
                    provider: "password",
                    createdAt: "2024-04-09T12:00:00Z",
                    updatedAt: "2024-04-09T12:00:00Z"
                )
            },
            fetchSubscription: fetchSubscription,
            syncSubscription: syncSubscription ?? fetchSubscription
        )
    }

    private func activeSubscription() -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true
        )
    }

    private func waitForPromptCount(
        _ expectedCount: Int,
        in prompt: RecordingCloudModelDefaultsPrompt
    ) async throws {
        for _ in 0 ..< 50 {
            if prompt.confirmCallCount == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(expectedCount) cloud default prompt(s)")
    }
}

@MainActor
private final class RecordingCloudModelDefaultsPrompt: CloudModelDefaultsPrompting {
    private let shouldConfirm: Bool
    private let onConfirm: () -> Void
    private(set) var confirmCallCount = 0
    private(set) var cloudDefaultsConfirmCallCount = 0

    init(shouldConfirm: Bool, onConfirm: @escaping () -> Void = {}) {
        self.shouldConfirm = shouldConfirm
        self.onConfirm = onConfirm
    }

    func confirmSwitchToCloudDefaults() -> Bool {
        confirmCallCount += 1
        cloudDefaultsConfirmCallCount += 1
        onConfirm()
        return shouldConfirm
    }
}
