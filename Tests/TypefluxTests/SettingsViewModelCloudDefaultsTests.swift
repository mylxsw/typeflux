@testable import Typeflux
import Combine
import SwiftUI
import XCTest

@MainActor
final class SettingsViewModelCloudDefaultsTests: XCTestCase {
    func testCloudDefaultsNotificationSyncsModelSelectionState() async throws {
        let originalLanguage = AppLocalization.shared.language
        if CloudSpeechAcceptanceCapture.enabled { AppLocalization.shared.setLanguage(.simplifiedChinese) }
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        let suiteName = "SettingsViewModelCloudDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.sttProvider = .localModel
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI

        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: NoopLocalSTTModelManager()
        )
        viewModel.setModelDomain(.llm)

        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud
        settingsStore.defaults.set("cloud:default", forKey: "llm.profile.reference")
        NotificationCenter.default.post(name: .cloudAccountModelDefaultsDidApply, object: settingsStore)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.sttProvider, .typefluxOfficial)
        XCTAssertEqual(viewModel.llmProvider, .openAICompatible)
        XCTAssertEqual(viewModel.llmRemoteProvider, .typefluxCloud)
        XCTAssertEqual(viewModel.modelLibrary.rewriteReference, "cloud:default")
        XCTAssertEqual(viewModel.focusedModelProvider, .typefluxCloud)
        XCTAssertEqual(viewModel.toastMessage, L("cloud.subscriptionSwitch.successBody"))
    }

    func testCloudSpeechTestDistinguishesCheckingFailureAndConfirmedDenial() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            settings.interfaceStyle = .classic
            settings.appearanceMode = .light
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let profile = AskModelProfile(name: "DeepSeek", baseURL: "https://example.test/v1", model: "DeepSeek Flash")
            try library.save(profile, key: "fixture")
            library.defaultReference = profile.reference
            library.rewriteReference = "cloud:default"
            settings.sttProvider = .typefluxOfficial
            let model = StudioViewModel(settingsStore: settings, historyStore: EmptyHistoryStore(),
                                        initialSection: .models, modelManager: NoopOllamaModelManager(),
                                        localModelManager: FixtureLocalModels(), modelLibrary: library)
            model.selectModelPageTab(.scenes)
            let auth = AuthState.shared
            let priorSessionGeneration = auth.sessionGeneration
            let priorGeneration = auth.subscriptionSnapshotGeneration
            let priorSubscription = auth.subscription
            let priorError = auth.subscriptionError
            let priorLoading = auth.isLoadingSubscription
            let priorLoadGeneration = auth.subscriptionLoadGeneration
            let priorSyncGeneration = auth.subscriptionSyncGeneration
            let priorProfile = auth.userProfile
            let priorSessionToken = auth.inMemorySessionToken
            let priorStoredToken = auth.cachedStoredToken
            let priorRefreshToken = auth.cachedRefreshToken
            // These windows can refresh account details on appearance. Keep them
            // on the fixture even if another suite initialized shared auth.
            auth.sessionGeneration += 1
            auth.inMemorySessionToken = nil
            auth.cachedStoredToken = nil
            auth.cachedRefreshToken = nil
            auth.isLoggedIn = true
            auth.userProfile = UserProfile(id: "design-fixture", email: "preview@example.test", name: "示例账号",
                                           status: 1, provider: "password", createdAt: "", updatedAt: "")
            defer {
                auth.isLoggedIn = false
                auth.userProfile = priorProfile
                auth.sessionGeneration = priorSessionGeneration
                auth.subscriptionSnapshotGeneration = priorGeneration
                auth.subscription = priorSubscription
                auth.subscriptionError = priorError
                auth.isLoadingSubscription = priorLoading
                auth.subscriptionLoadGeneration = priorLoadGeneration
                auth.subscriptionSyncGeneration = priorSyncGeneration
                auth.inMemorySessionToken = priorSessionToken
                auth.cachedStoredToken = priorStoredToken
                auth.cachedRefreshToken = priorRefreshToken
            }

            if CloudSpeechAcceptanceCapture.enabled {
                try await SettingsBehaviorTestSupport.withWindow(StudioView(viewModel: model),
                                                                 width: 980, height: 555) { _, host in
                    NotificationCenter.default.post(name: .cloudAccountModelDefaultsDidApply, object: settings)
                    try await SettingsBehaviorTestSupport.wait { model.toastMessage != nil }
                    try await Task.sleep(for: .milliseconds(250))
                    try CloudSpeechAcceptanceCapture.save(host, name: "02-model-settings")
                }
            }

            model.toastMessage = nil
            model.selectModelPageTab(.speech)
            model.focusModelProvider(.typefluxOfficial)
            model.isShowingSpeechProviderDetail = true
            let failedCheck = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil },
                loadStoredUserProfile: { nil }, fetchSubscription: { _ in throw URLError(.timedOut) })
            failedCheck.isLoggedIn = true
            failedCheck.inMemorySessionToken = ("fixture-token", Int(Date().timeIntervalSince1970) + 3600)
            failedCheck.subscriptionLoadGeneration = failedCheck.sessionGeneration
            model.testSTTConnection(auth: failedCheck)
            try await SettingsBehaviorTestSupport.wait { model.sttConnectionTestState == .idle }
            XCTAssertTrue(failedCheck.isCheckingCloudASRAccess)
            XCTAssertNil(failedCheck.settledCloudASRAccess)

            failedCheck.subscriptionLoadGeneration = nil
            auth.subscriptionSnapshotGeneration = nil
            model.testSTTConnection(auth: failedCheck)
            try await SettingsBehaviorTestSupport.wait {
                if case let .notice(message) = model.sttConnectionTestState {
                    return message == L("settings.models.cloudSpeechAccessCheckFailed")
                }
                return false
            }
            if CloudSpeechAcceptanceCapture.enabled {
                try await SettingsBehaviorTestSupport.withWindow(StudioView(viewModel: model),
                                                                 width: 980, height: 500) { _, host in
                    try CloudSpeechAcceptanceCapture.save(host, name: "03b-permission-check-failed")
                }
            }

            auth.subscription = .none
            auth.subscriptionSnapshotGeneration = auth.sessionGeneration
            auth.subscriptionError = nil
            auth.isLoadingSubscription = false
            auth.subscriptionLoadGeneration = nil
            auth.subscriptionSyncGeneration = nil
            XCTAssertEqual(FeatureAuth.capture().hasConfirmedSubscription, true)
            model.testSTTConnection()
            try await SettingsBehaviorTestSupport.wait {
                if case let .notice(message) = model.sttConnectionTestState {
                    return message == L("settings.models.cloudSpeechAccessUnavailable")
                }
                return false
            }
            if CloudSpeechAcceptanceCapture.enabled {
                try await SettingsBehaviorTestSupport.withWindow(StudioView(viewModel: model),
                                                                 width: 980, height: 500) { _, host in
                    try CloudSpeechAcceptanceCapture.save(host, name: "03-speech-detail")
                }
            }
        }
    }

    func testCloudRewriteSelectionShowsSavedSpeechProviderUntilSpeechIsSwitched() async throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.rewriteOnly.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.sttProvider = .aliCloud
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .openAI
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: NoopLocalSTTModelManager()
        )
        viewModel.setModelDomain(.stt)

        let refreshed = expectation(description: "Cloud rewrite selection received")
        let rewriteSelection = viewModel.$llmRemoteProvider.dropFirst().first().sink { provider in
            XCTAssertEqual(provider, .typefluxCloud)
            refreshed.fulfill()
        }
        defer { rewriteSelection.cancel() }
        settingsStore.llmRemoteProvider = .typefluxCloud
        NotificationCenter.default.post(name: .cloudAccountModelDefaultsDidApply, object: settingsStore)
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(viewModel.sttProvider, .aliCloud)
        XCTAssertEqual(viewModel.focusedModelProvider, .aliCloud)
        XCTAssertEqual(settingsStore.sttProvider, .aliCloud)

        let speechSelection = viewModel.$sttProvider.dropFirst().first().sink { provider in
            XCTAssertEqual(provider, .typefluxOfficial)
            XCTAssertEqual(settingsStore.sttProvider, provider)
        }
        defer { speechSelection.cancel() }
        viewModel.setSTTProvider(.typefluxOfficial)
        XCTAssertEqual(viewModel.sttProvider, .typefluxOfficial)
        XCTAssertEqual(settingsStore.sttProvider, .typefluxOfficial)
        XCTAssertEqual(viewModel.focusedModelProvider, .typefluxOfficial)
    }

    func testAliCloudModelConfigurationCanBeSelectedAndSaved() throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.aliCloud.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.aliCloudModel = "fun-asr-realtime"
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: NoopLocalSTTModelManager()
        )

        XCTAssertEqual(viewModel.aliCloudModel, "fun-asr-realtime")

        viewModel.focusModelProvider(.aliCloud)
        viewModel.setAliCloudModel("paraformer-realtime-v2")
        viewModel.applyModelConfiguration(shouldShowToast: false)

        XCTAssertEqual(settingsStore.aliCloudModel, "paraformer-realtime-v2")
    }

    func testUnavailableLocalSTTModelFocusDoesNotCommitUntilPrepareSucceeds() async throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.localSTT.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        let localModelManager = CapturingLocalSTTModelManager()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: localModelManager,
            notificationService: NoopLocalNotificationService()
        )

        viewModel.focusLocalSTTModel(LocalSTTModel.qwen3ASR)

        XCTAssertEqual(viewModel.localSTTFocusedModel, LocalSTTModel.qwen3ASR)
        XCTAssertEqual(viewModel.localSTTModel, LocalSTTModel.senseVoiceSmall)
        XCTAssertEqual(settingsStore.localSTTModel, LocalSTTModel.senseVoiceSmall)

        viewModel.prepareLocalSTTModel(LocalSTTModel.qwen3ASR)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(localModelManager.preparedModel, LocalSTTModel.qwen3ASR)
        XCTAssertEqual(viewModel.localSTTModel, LocalSTTModel.qwen3ASR)
        XCTAssertEqual(settingsStore.localSTTModel, LocalSTTModel.qwen3ASR)
    }

    func testManualLocalSTTPreparationPublishesMenuBarDownloadProgress() async throws {
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let suiteName = "SettingsViewModelCloudDefaultsTests.menuProgress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        let localModelManager = CapturingLocalSTTModelManager()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: localModelManager,
            notificationService: NoopLocalNotificationService()
        )
        let progressExpectation = expectation(description: "manual local model download progress")
        let observer = NotificationCenter.default.addObserver(
            forName: .localModelDownloadProgressDidChange,
            object: nil,
            queue: .main
        ) { _ in
            if case .downloading(model: .qwen3ASR, progress: let progress) =
                LocalModelDownloadProgressCenter.shared.status,
                progress > 0 {
                progressExpectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        viewModel.prepareLocalSTTModel(LocalSTTModel.qwen3ASR)

        await fulfillment(of: [progressExpectation], timeout: 2)
    }

    func testFocusedLocalSTTModelMirrorsSharedDownloadProgress() async throws {
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let suiteName = "SettingsViewModelCloudDefaultsTests.sharedProgress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .whisperLocal
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: NoopLocalSTTModelManager(),
            notificationService: NoopLocalNotificationService()
        )

        LocalModelDownloadProgressCenter.shared.reportDownloading(model: .whisperLocal, progress: 0.35)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.localSTTPreparationProgress, 0.35, accuracy: 0.001)
        XCTAssertEqual(viewModel.localSTTDisplayedPreparationProgress, 0.35, accuracy: 0.001)
        XCTAssertEqual(viewModel.localSTTPreparationPercentText, "35%")
        XCTAssertEqual(viewModel.localSTTPreparationDetail, L("settings.models.localSTT.preparing"))
    }

    func testUnfocusedLocalSTTModelDoesNotMirrorSharedDownloadProgress() async throws {
        LocalModelDownloadProgressCenter.shared.clear()
        defer { LocalModelDownloadProgressCenter.shared.clear() }

        let suiteName = "SettingsViewModelCloudDefaultsTests.unfocusedSharedProgress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: NoopLocalSTTModelManager(),
            notificationService: NoopLocalNotificationService()
        )
        viewModel.focusLocalSTTModel(.qwen3ASR)

        LocalModelDownloadProgressCenter.shared.reportDownloading(model: .whisperLocal, progress: 0.35)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.localSTTFocusedModel, .qwen3ASR)
        XCTAssertEqual(viewModel.localSTTPreparationProgress, 0)
        XCTAssertEqual(viewModel.localSTTDisplayedPreparationProgress, 0, accuracy: 0.001)
        XCTAssertEqual(viewModel.localSTTPreparationPercentText, "0%")
    }

    func testFocusingDifferentLocalSTTModelDuringPreparationPreventsStaleCommit() async throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.stalePreparation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        let preparationStarted = expectation(description: "local model preparation started")
        let localModelManager = SuspendedLocalSTTModelManager(started: preparationStarted)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: localModelManager,
            notificationService: NoopLocalNotificationService()
        )

        viewModel.prepareLocalSTTModel(.qwen3ASR)
        await fulfillment(of: [preparationStarted], timeout: 2)

        viewModel.focusLocalSTTModel(.funASR)
        localModelManager.finishPreparation()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.localSTTModel, .senseVoiceSmall)
        XCTAssertEqual(viewModel.localSTTFocusedModel, .funASR)
        XCTAssertEqual(settingsStore.localSTTModel, .senseVoiceSmall)
        XCTAssertFalse(viewModel.isPreparingLocalSTT)
    }

    func testDeletingSelectedLocalSTTModelSelectsFirstDownloadedFallback() throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.deleteFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .qwen3ASR
        let localModelManager = MutableAvailabilityLocalSTTModelManager(
            availableModels: [.qwen3ASR, .funASR, .whisperLocal]
        )
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: localModelManager,
            notificationService: NoopLocalNotificationService()
        )

        viewModel.deleteLocalSTTModel(.qwen3ASR)

        XCTAssertEqual(viewModel.localSTTModel, .funASR)
        XCTAssertEqual(viewModel.localSTTFocusedModel, .funASR)
        XCTAssertEqual(settingsStore.localSTTModel, .funASR)
        XCTAssertTrue(viewModel.isLocalSTTPrepared)
        XCTAssertEqual(
            viewModel.localSTTStatus,
            L("settings.models.localSTT.readyNamed", LocalSTTModel.funASR.displayName)
        )
    }

    func testDeletingOnlyDownloadedLocalSTTModelFallsBackToUndownloadedSenseVoice() throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.deleteDefaultFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .qwen3ASR
        let localModelManager = MutableAvailabilityLocalSTTModelManager(availableModels: [.qwen3ASR])
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: localModelManager,
            notificationService: NoopLocalNotificationService()
        )

        viewModel.deleteLocalSTTModel(.qwen3ASR)

        XCTAssertEqual(viewModel.localSTTModel, .senseVoiceSmall)
        XCTAssertEqual(viewModel.localSTTFocusedModel, .senseVoiceSmall)
        XCTAssertEqual(settingsStore.localSTTModel, .senseVoiceSmall)
        XCTAssertFalse(viewModel.isLocalSTTPrepared)
        XCTAssertEqual(viewModel.localSTTStatus, L("settings.models.localSTT.notPrepared"))
        XCTAssertEqual(viewModel.localSTTPreparationProgress, 0)
    }

    func testDeletingFocusedUnselectedLocalSTTModelKeepsCurrentSelection() throws {
        let suiteName = "SettingsViewModelCloudDefaultsTests.deleteFocused.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        let localModelManager = MutableAvailabilityLocalSTTModelManager(
            availableModels: [.senseVoiceSmall, .qwen3ASR]
        )
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: EmptyHistoryStore(),
            initialSection: .models,
            modelManager: NoopOllamaModelManager(),
            localModelManager: localModelManager,
            notificationService: NoopLocalNotificationService()
        )
        viewModel.focusLocalSTTModel(.qwen3ASR)

        viewModel.deleteLocalSTTModel(.qwen3ASR)

        XCTAssertEqual(viewModel.localSTTModel, .senseVoiceSmall)
        XCTAssertEqual(viewModel.localSTTFocusedModel, .senseVoiceSmall)
        XCTAssertEqual(settingsStore.localSTTModel, .senseVoiceSmall)
        XCTAssertTrue(viewModel.isLocalSTTPrepared)
    }
}

private final class NoopOllamaModelManager: OllamaModelManaging {
    func ensureModelReady(settingsStore _: SettingsStore) async throws {}
}

private final class NoopLocalSTTModelManager: LocalSTTModelManaging {
    func prepareModel(
        settingsStore _: SettingsStore,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {}

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        false
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}

    func storagePath(for _: LocalSTTConfiguration) -> String {
        "/tmp/typeflux-local-model"
    }
}

private final class CapturingLocalSTTModelManager: LocalSTTModelManaging {
    private(set) var preparedModel: LocalSTTModel?

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        preparedModel = settingsStore.localSTTModel
        onUpdate?(LocalSTTPreparationUpdate(
            message: "ready",
            progress: 1,
            storagePath: "/tmp/typeflux-local-model",
            source: "test"
        ))
    }

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        false
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}

    func storagePath(for _: LocalSTTConfiguration) -> String {
        "/tmp/typeflux-local-model"
    }
}

private struct NoopLocalNotificationService: LocalNotificationSending {
    func sendLocalNotification(title _: String, body _: String, identifier _: String) async {}
}

private final class SuspendedLocalSTTModelManager: LocalSTTModelManaging {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Error>?

    init(started: XCTestExpectation) {
        self.started = started
    }

    func prepareModel(
        settingsStore _: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        started.fulfill()
        onUpdate?(LocalSTTPreparationUpdate(
            message: "downloading",
            progress: 0.25,
            storagePath: "/tmp/typeflux-local-model",
            source: "test"
        ))
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finishPreparation() {
        continuation?.resume()
        continuation = nil
    }

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        false
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}

    func storagePath(for _: LocalSTTConfiguration) -> String {
        "/tmp/typeflux-local-model"
    }
}

private final class MutableAvailabilityLocalSTTModelManager: LocalSTTModelManaging {
    private var availableModels: Set<LocalSTTModel>

    init(availableModels: Set<LocalSTTModel>) {
        self.availableModels = availableModels
    }

    func prepareModel(
        settingsStore _: SettingsStore,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {}

    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo? {
        guard availableModels.contains(settingsStore.localSTTModel) else { return nil }
        return LocalSTTPreparedModelInfo(
            storagePath: storagePath(for: LocalSTTConfiguration(settingsStore: settingsStore)),
            sourceDisplayName: "test"
        )
    }

    func isModelAvailable(_ model: LocalSTTModel) -> Bool {
        availableModels.contains(model)
    }

    func deleteModelFiles(_ model: LocalSTTModel) throws {
        availableModels.remove(model)
    }

    func storagePath(for configuration: LocalSTTConfiguration) -> String {
        "/tmp/typeflux-local-model/\(configuration.model.rawValue)"
    }
}

private final class EmptyHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        FileManager.default.temporaryDirectory
    }
}
