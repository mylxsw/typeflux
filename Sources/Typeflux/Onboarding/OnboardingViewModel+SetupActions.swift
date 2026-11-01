import Foundation

extension OnboardingViewModel {
    var isSetupActionRunning: Bool { isPageBusy }

    /// Page models own their inline setup; the shell only advances ready pages.
    func performSetupAction() {
        guard !isPageBusy else { return }
        if canAdvance { advance() } else { pagePrimaryAction?() }
    }

    func selectSpeechProvider(_ provider: STTProvider) {
        let wasDeferred = settingsStore.onboardingSpeechDeferred
        settingsStore.sttProvider = provider
        settingsStore.onboardingSpeechDeferred = wasDeferred
        speechSkipped = false
        refreshSetup()
    }

    func requestSetupSkip() {
        switch currentStep {
        case .speech: skipConfirmation = .speech
        case .llm: skipConfirmation = .language
        default: skipConfirmation = .allModels
        }
    }
}
