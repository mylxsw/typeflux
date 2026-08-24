@testable import Typeflux
import XCTest

@MainActor
final class CloudLoginSyncCoordinatorTests: XCTestCase {
    func testPromptsAndAppliesCloudDefaultsAfterLoginWithExistingEntitlement() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.localOptimizationEnabled = true
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)
        let authState = makeAuthState(subscription: activeSubscription())

        await authState.handleLoginSuccess(
            token: "token-1",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        )

        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertFalse(settingsStore.localOptimizationEnabled)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        XCTAssertEqual(prompt.confirmCallCount, 1)
        XCTAssertEqual(prompt.successCallCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testPromptsAndAppliesCloudDefaultsAfterLoginWithoutEntitlement() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)
        let authState = makeAuthState(subscription: .none)

        await authState.handleLoginSuccess(
            token: "token-1",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        )

        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(prompt.confirmCallCount, 1)
        XCTAssertEqual(prompt.successCallCount, 1)
        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }

    func testPromptsAndAppliesCloudDefaultsAfterCheckoutSubscriptionEntitlement() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.llmProvider = .ollama
        settingsStore.llmRemoteProvider = .openAI

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: nil)

        try await waitForPromptCount(1, in: prompt)

        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        XCTAssertEqual(settingsStore.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
        XCTAssertEqual(prompt.confirmCallCount, 1)
        XCTAssertEqual(prompt.successCallCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testPostsModelDefaultsNotificationAfterApplyingCloudDefaults() async {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .localModel
        settingsStore.llmProvider = .ollama

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)
        let expectation = expectation(description: "cloud defaults notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .cloudAccountModelDefaultsDidApply,
            object: settingsStore,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        coordinator.offerCloudDefaultsIfNeeded()

        await fulfillment(of: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        withExtendedLifetime(coordinator) {}
    }

    func testKeepsCurrentProvidersWhenPromptDeclined() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .whisperAPI
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: false)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: nil)

        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(settingsStore.sttProvider, .whisperAPI)
        XCTAssertEqual(settingsStore.llmProvider, .openAICompatible)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .openAI)
        XCTAssertEqual(prompt.successCallCount, 0)
        withExtendedLifetime(coordinator) {}
    }

    func testAppliesCloudDefaultsWhenOnlyOneProviderDiffers() async throws {
        let settingsStore = makeSettingsStore()
        // STT is already Cloud, but LLM is not — should still switch + notify.
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: nil)

        try await waitForPromptCount(1, in: prompt)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .typefluxCloud)
        withExtendedLifetime(coordinator) {}
    }

    func testStaysSilentWhenAlreadyFullyOnCloud() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)

        NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: nil)

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(prompt.successCallCount, 0)
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

        let prompt = RecordingCloudModelDefaultsPrompt(shouldConfirm: true)
        let coordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore, promptPresenter: prompt)

        NotificationCenter.default.post(
            name: Notification.Name("SomeOtherNotification"),
            object: nil
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(prompt.confirmCallCount, 0)
        XCTAssertEqual(prompt.successCallCount, 0)
        XCTAssertEqual(settingsStore.sttProvider, .whisperAPI)
        XCTAssertEqual(settingsStore.llmProvider, .ollama)
        XCTAssertEqual(settingsStore.llmRemoteProvider, .openAI)
        withExtendedLifetime(coordinator) {}
    }

    // MARK: - Helpers

    private func makeSettingsStore() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "CloudLoginSyncCoordinatorTests.\(UUID().uuidString)")!
        return SettingsStore(defaults: defaults)
    }

    private func makeAuthState(subscription: BillingSubscriptionSnapshot) -> AuthState {
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
            fetchSubscription: { _ in subscription }
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
    private(set) var confirmCallCount = 0
    private(set) var successCallCount = 0

    init(shouldConfirm: Bool) {
        self.shouldConfirm = shouldConfirm
    }

    func confirmSwitchToCloudDefaults() -> Bool {
        confirmCallCount += 1
        return shouldConfirm
    }

    func showCloudDefaultsApplied() {
        successCallCount += 1
    }
}
