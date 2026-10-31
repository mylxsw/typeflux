import Foundation

extension OnboardingViewModel {
    var isSetupActionRunning: Bool {
        switch currentStep {
        case .cloud: isCheckingCloud
        case .stt: configurationModel?.sttConnectionTestState == .testing
        case .llm: languageTestState == .testing
        default: false
        }
    }

    var setupPrimaryTitle: String {
        if isSetupActionRunning {
            return L(currentStep == .cloud ? "setup.cloud.checking" : "setup.status.testing")
        }
        switch currentStep {
        case .cloud:
            if !authState.isLoggedIn { return L("setup.cloud.signInContinue") }
            if cloudError != nil { return L("setup.action.retry") }
        case .stt:
            if !speechConfigured { return L("setup.speech.configure") }
            if !speechVerified { return L("setup.action.testAndContinue") }
        case .llm:
            if !languageConfigured { return L("setup.language.configure") }
            if !languageVerified { return L("setup.action.testAndContinue") }
        default: break
        }
        return L("onboarding.v2.action.continue")
    }

    /// Configuration and validation share one primary action. Editors and login remain the existing flows.
    func performSetupAction() {
        guard !isSetupActionRunning else { return }
        if canAdvance { advance(); return }
        switch currentStep {
        case .cloud:
            requestedSetupAdvance = .cloud
            if authState.isLoggedIn {
                Task { await checkCloud() }
            } else {
                presentLogin()
            }
        case .stt:
            guard speechConfigured else { editModels(.stt); return }
            guard let configurationModel else { return }
            requestedSetupAdvance = .stt
            let wasDeferred = settingsStore.onboardingSpeechDeferred
            configurationModel.setSTTProvider(settingsStore.sttProvider)
            settingsStore.onboardingSpeechDeferred = wasDeferred
            configurationModel.testSTTConnection()
        case .llm:
            guard languageConfigured else { editModels(.llm); return }
            requestedSetupAdvance = .llm
            testLanguageModel()
        default: break
        }
    }

    func selectSpeechProvider(_ provider: STTProvider) {
        requestedSetupAdvance = nil
        let wasDeferred = settingsStore.onboardingSpeechDeferred
        configurationModel?.selectModelPageTab(.speech)
        configurationModel?.setSTTProvider(provider)
        if let configurationModel {
            configurationModel.focusModelProvider(configurationModel.focusedModelProvider)
        }
        settingsStore.sttProvider = provider
        settingsStore.onboardingSpeechDeferred = wasDeferred
        speechSkipped = false
        refreshSetup()
    }

    func requestSetupSkip() {
        requestedSetupAdvance = nil
        switch currentStep {
        case .stt: skipConfirmation = .speech
        case .llm: skipConfirmation = .language
        default: skipConfirmation = .allModels
        }
    }

    /// A late test or login result must never navigate after Back, Skip, or opening an editor.
    func completeRequestedSetupAdvanceIfReady() {
        guard let requestedSetupAdvance else { return }
        guard currentStep == requestedSetupAdvance, skipConfirmation == nil, modelEditorDomain == nil else {
            self.requestedSetupAdvance = nil
            return
        }
        if canAdvance {
            self.requestedSetupAdvance = nil
            advance()
            return
        }
        if currentStep == .stt || currentStep == .llm {
            let state = currentStep == .stt ? configurationModel?.sttConnectionTestState : languageTestState
            switch state {
            case .failure, .notice, .idle: self.requestedSetupAdvance = nil
            default: break
            }
        }
        if currentStep == .cloud, cloudError != nil { self.requestedSetupAdvance = nil }
    }
}
