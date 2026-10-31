import AppKit
import CryptoKit
import Foundation

extension OnboardingViewModel {
    enum ServiceRoute: String { case cloud, custom, launcherOnly }
    enum SkipTarget: String, Identifiable {
        case allModels, speech, language, permissions
        var id: String {
            rawValue
        }

        var message: String {
            L("setup.skip.\(rawValue).message")
        }
    }

    var currentStage: String {
        switch currentStep {
        case .welcome, .services: "services"
        case .cloud, .stt, .llm: "models"
        case .permissions: "permissions"
        default: "practice"
        }
    }

    var speechConfigured: Bool {
        FeatureSetupStatus.speechReason(
            settings: settingsStore,
            loggedIn: authState.isLoggedIn,
            cloudAllowed: authState.canUseCloudASR,
            localAvailable: localModelManager?.isModelAvailable(
                settingsStore
                    .sttProvider == .typefluxOfficial ? .senseVoiceSmall : settingsStore
                    .localSTTModel
            ) ?? false,
            googleAuthorized: GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable()
        ) == nil
    }

    var languageConfigured: Bool {
        guard case .ready = LLMConfigurationValidator(settingsStore: settingsStore,
                                                      isLoggedIn: authState.isLoggedIn).validate(),
            let (provider, model) = modelLibrary.registry.resolve(modelLibrary.rewriteReference)
        else { return false }
        return modelLibrary.selectionReason(model, provider: provider, hasImage: false,
                                            loggedIn: authState.isLoggedIn) == nil
            && modelLibrary.selectionReason(model, provider: provider, hasImage: false,
                                            loggedIn: authState.isLoggedIn, scenario: "rewrite") == nil
    }

    var speechVerified: Bool {
        if settingsStore.sttProvider == .localModel || settingsStore
            .sttProvider == .appleSpeech { return speechConfigured }
        if settingsStore.sttProvider == .typefluxOfficial {
            guard authState.canUseCloudASR else { return false }
            if cloudCheckCompleted { return true }
        }
        if case .success = configurationModel?.sttConnectionTestState { return true }
        return false
    }

    var languageVerified: Bool {
        if case .success = languageTestState { return verifiedLanguageSignature == languageConfigurationSignature }
        return false
    }

    var speechStatusText: String {
        if settingsStore.sttProvider == .localModel {
            if case let .downloading(model, progress) = LocalModelDownloadProgressCenter.shared.status,
               model == settingsStore.localSTTModel {
                return L("setup.status.downloading", Int(progress * 100))
            }
            if case let .failed(model, message) = LocalModelDownloadProgressCenter.shared.status,
               model == settingsStore.localSTTModel { return message }
        }
        return speechConfigured ? L(speechVerified ? "setup.status.configured" : "setup.status.testNeeded")
            : L("setup.status.notSetUp")
    }

    var languageStatusText: String {
        languageConfigured ? L("setup.status.configured") : L("setup.status.notSetUp")
    }

    var voicePermissionsGranted: Bool {
        PrivacyGuard.requiredPermissionIDs(settingsStore: settingsStore).allSatisfy { id in
            permissions.first(where: { $0.id == id })?.isGranted == true
        }
    }

    var voiceHotkeyReady: Bool {
        isGlobeKeyReady || activationHotkey.signature != HotkeyBinding.defaultActivation.signature
    }

    var voiceReady: Bool {
        speechConfigured && voicePermissionsGranted && voiceHotkeyReady
    }

    func chooseRoute(_ route: ServiceRoute) {
        requestedSetupAdvance = nil
        serviceRoute = route
        speechSkipped = false
        aiSkipped = false
    }

    func guideShortcuts(for feature: OnboardingFeature) -> [OnboardingShortcut] {
        shortcuts(for: feature).filter { shortcut in
            shortcut.id != "voice.rewrite" || (!aiSkipped && languageConfigured)
        }
    }

    func refreshSetup() {
        modelLibrary.reloadFeaturePreferences()
        setupRevision += 1
        if languageTestState == .testing, testingLanguageSignature != languageConfigurationSignature {
            languageTestTask?.cancel()
            requestedSetupAdvance = nil
            languageTestState = .idle
            testingLanguageSignature = nil
        }
        if case .success = languageTestState,
           verifiedLanguageSignature != languageConfigurationSignature { languageTestState = .idle }
        if let testingLanguageSignature, testingLanguageSignature != languageConfigurationSignature {
            languageTestState = .idle
            requestedSetupAdvance = nil
        }
        updateVoicePractice()
        completeRequestedSetupAdvanceIfReady()
    }

    var languageConfigurationSignature: String {
        let value = settingsStore.textLLMConfiguration()
        let data = [modelLibrary.rewriteReference, value.baseURL, value.model, value.apiKey,
                    String(describing: value.effectiveAPIStyle)].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func updateVoicePractice() {
        guard currentStep == .voice, !voicePracticeText.isEmpty, let historyStore,
              let began = voicePracticeBeganAt else { return }
        voicePracticeSucceeded = historyStore.list(limit: 5, offset: 0, searchQuery: nil).contains { record in
            guard record.date >= began, record.transcriptionStatus == .succeeded,
                  record.applyStatus == .succeeded,
                  let text = record.postProcessedText ?? record.transcriptText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return voicePracticeText.contains(text)
        }
    }

    func checkCloud() async {
        guard authState.isLoggedIn, !isCheckingCloud else { return }
        isCheckingCloud = true
        cloudCheckCompleted = false
        cloudError = nil
        let snapshot = await authState.refreshSubscription()
        guard !Task.isCancelled else { isCheckingCloud = false; return }
        cloudCheckCompleted = snapshot != nil
        cloudError = snapshot == nil ? L("setup.cloud.checkFailed") : nil
        isCheckingCloud = false
        refreshSetup()
    }

    func applyCloudSelection() {
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud
        modelLibrary.defaultReference = "cloud:default"
        modelLibrary.rewriteReference = "cloud:default"
        aiSkipped = false
        settingsStore.onboardingAIDeferred = false
        if authState.canUseCloudASR {
            settingsStore.sttProvider = .typefluxOfficial
            settingsStore.onboardingSpeechDeferred = false
            speechSkipped = false
        }
        settingsStore.applyDefaultPersonaIfLLMConfigured()
        refreshSetup()
    }

    func skipMessage(for target: SkipTarget) -> String {
        if target == .allModels, speechConfigured || languageConfigured { return L("setup.skip.existingModels") }
        if target == .speech, speechConfigured { return L("setup.skip.existingSpeech") }
        if target == .language, languageConfigured { return L("setup.skip.existingAI") }
        guard target == .permissions else { return target.message }
        var impacts = requiredPermissions.filter { !$0.isGranted }.map {
            L("setup.permission.\($0.id.rawValue).impact")
        }
        if needsGlobeKeySetup { impacts.append(L("setup.permission.keyboardImpact")) }
        return (impacts + [L("setup.permission.later")]).joined(separator: "\n\n")
    }

    func confirmSkip(_ confirmedTarget: SkipTarget? = nil) {
        guard let target = confirmedTarget ?? skipConfirmation else { return }
        requestedSetupAdvance = nil
        skipConfirmation = nil
        reportCurrentStepCompleted(skipped: true)
        switch target {
        case .allModels:
            serviceRoute = .launcherOnly
            speechSkipped = true; aiSkipped = true
            settingsStore.onboardingSpeechDeferred = true
            settingsStore.onboardingAIDeferred = true
            currentStep = .permissions
        case .speech:
            speechSkipped = true
            settingsStore.onboardingSpeechDeferred = true
            advanceToNextStepOrComplete()
        case .language:
            aiSkipped = true
            settingsStore.onboardingAIDeferred = true
            advanceToNextStepOrComplete()
        case .permissions:
            settingsStore.onboardingPermissionsDeferred = true
            advanceToNextStepOrComplete()
        }
    }

    func editModels(_ domain: StudioModelDomain) {
        requestedSetupAdvance = nil
        configurationModel?.selectModelPageTab(ModelPageTab(domain: domain))
        if domain == .stt, let configurationModel {
            configurationModel.focusModelProvider(configurationModel.focusedModelProvider)
            configurationModel.isShowingSpeechProviderDetail = true
        }
        modelEditorDomain = domain
    }

    /// Assign both consumers, so configuring rewriting also enables new conversations.
    func selectLanguageModel(_ reference: String) {
        requestedSetupAdvance = nil
        languageTestTask?.cancel()
        modelLibrary.rewriteReference = reference
        modelLibrary.defaultReference = reference
        verifiedLanguageSignature = nil
        testingLanguageSignature = nil
        languageTestState = .idle
        refreshSetup()
    }

    func testLanguageModel() {
        guard let (provider, model) = modelLibrary.registry.resolve(modelLibrary.rewriteReference),
              modelLibrary.selectionReason(model, provider: provider, hasImage: false,
                                           loggedIn: authState.isLoggedIn, scenario: "rewrite") == nil else { return }
        languageTestTask?.cancel()
        let reference = model.reference
        let signature = languageConfigurationSignature
        let connection = modelLibrary.connection(provider, model: model)
        let probe = languageConnectionProbe
        testingLanguageSignature = signature
        languageTestState = .testing
        languageTestTask = Task {
            defer { refreshSetup() }
            do {
                let reply = try await ConnectionTestSupport.runWithTimeout {
                    try await probe(provider, connection)
                }
                try Task.checkCancellation()
                guard reference == modelLibrary.rewriteReference,
                      signature == languageConfigurationSignature else {
                    languageTestState = .idle; return
                }
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AskStreamError.invalidResponse
                }
                verifiedLanguageSignature = signature
                languageTestState = .success(firstTokenMs: 0, totalMs: 0, preview: "")
            } catch {
                guard !Task.isCancelled, signature == languageConfigurationSignature else { return }
                languageTestState = .failure(message: error.localizedDescription)
            }
        }
    }
}
