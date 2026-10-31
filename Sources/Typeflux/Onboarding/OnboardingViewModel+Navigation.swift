import SwiftUI

extension OnboardingViewModel {
    var visibleSteps: [Step] {
        Step.visibleSteps(for: serviceRoute)
    }

    var canGoBack: Bool {
        visibleSteps.firstIndex(of: currentStep).map { $0 > 0 } ?? false
    }

    var isLastStep: Bool {
        currentStep == .try
    }

    var canAdvance: Bool {
        guard !isPageBusy else { return false }
        if let ready = pageReadiness {
            return ready
        }
        switch currentStep {
        case .cloud:
            return authState.isLoggedIn && cloudCheckCompleted && !isCheckingCloud && cloudError == nil
                && (authState.canUseCloudASR || (settingsStore.sttProvider == .localModel && speechConfigured))
        case .speech: return speechConfigured && speechVerified
        case .llm: return languageConfigured && languageVerified
        case .permissions: return allRequiredPermissionsGranted
        default: return true
        }
    }

    func chooseRoute(_ route: ServiceRoute) {
        requestedSetupAdvance = nil
        serviceRoute = route
        speechSkipped = false
        aiSkipped = false
        if !visibleSteps.contains(currentStep) {
            currentStep = .route
        }
    }

    func returnToRoute() {
        requestedSetupAdvance = nil
        skipConfirmation = nil
        stepDirection = -1
        currentStep = .route
    }

    func useCustomModels() {
        chooseRoute(.custom)
        stepDirection = 1
        currentStep = .speech
    }

    func resumeDeferredSetup() {
        requestedSetupAdvance = nil
        serviceRoute = .custom
        speechSkipped = settingsStore.onboardingSpeechDeferred
        aiSkipped = settingsStore.onboardingAIDeferred
        currentStep = speechSkipped ? .speech : aiSkipped ? .llm : .permissions
    }

    func advance() {
        guard canAdvance else { return }
        if currentStep == .route, serviceRoute == .launcherOnly {
            skipConfirmation = .allModels
            return
        }
        reportCurrentStepCompleted(skipped: false)
        if currentStep == .cloud {
            applyCloudSelection()
        }
        if currentStep == .speech {
            speechSkipped = false; settingsStore.onboardingSpeechDeferred = false
        }
        if currentStep == .llm {
            modelLibrary.defaultReference = modelLibrary.rewriteReference
            aiSkipped = false
            settingsStore.onboardingAIDeferred = false
        }
        if currentStep == .permissions {
            settingsStore.onboardingPermissionsDeferred = false
        }
        requestedSetupAdvance = nil
        advanceToNextStepOrComplete()
    }

    func goBack() {
        requestedSetupAdvance = nil
        guard let previous = adjacentStep(offset: -1) else { return }
        stepDirection = -1
        currentStep = previous
    }

    func skipPermissions() {
        guard currentStep == .permissions else { return }
        requestedSetupAdvance = nil
        skipConfirmation = .permissions
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

    func advanceToNextStepOrComplete() {
        if isLastStep {
            complete(); return
        }
        guard let next = adjacentStep(offset: 1) else { return }
        stepDirection = 1
        currentStep = next
    }

    private func adjacentStep(offset: Int) -> Step? {
        let steps = visibleSteps
        guard let index = steps.firstIndex(of: currentStep), steps.indices.contains(index + offset) else { return nil }
        return steps[index + offset]
    }
}
