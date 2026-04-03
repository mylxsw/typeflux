import AppKit
import Foundation
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case language = 0
        case sttProvider = 1
        case sttConfig = 2
        case llmProvider = 3
        case llmConfig = 4
        case permissions = 5
        case shortcuts = 6
    }

    @Published var currentStep: Step = .language
    @Published var stepDirection: Int = 1  // 1 = forward, -1 = backward

    // Language
    @Published var appLanguage: AppLanguage

    // STT Config
    @Published var sttProvider: STTProvider
    @Published var whisperBaseURL: String
    @Published var whisperAPIKey: String
    @Published var whisperModel: String
    @Published var freeSTTModel: String
    @Published var localSTTModel: LocalSTTModel
    @Published var multimodalLLMBaseURL: String
    @Published var multimodalLLMAPIKey: String
    @Published var multimodalLLMModel: String
    @Published var aliCloudAPIKey: String
    @Published var doubaoAppID: String
    @Published var doubaoAccessToken: String
    @Published var doubaoResourceID: String

    // LLM Config
    @Published var llmProvider: LLMProvider
    @Published var llmRemoteProvider: LLMRemoteProvider
    @Published var llmBaseURL: String
    @Published var llmModel: String
    @Published var llmAPIKey: String
    @Published var ollamaBaseURL: String
    @Published var ollamaModel: String

    // Permissions
    @Published var permissions: [PrivacyGuard.PermissionSnapshot] = []
    @Published var requestingPermissions: Set<PrivacyGuard.PermissionID> = []

    private let settingsStore: SettingsStore
    let onComplete: () -> Void

    init(settingsStore: SettingsStore, onComplete: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.onComplete = onComplete

        appLanguage = settingsStore.appLanguage
        sttProvider = {
            let p = settingsStore.sttProvider
            // Never show Apple Speech in onboarding
            return p == .appleSpeech ? .whisperAPI : p
        }()
        whisperBaseURL = settingsStore.whisperBaseURL
        whisperAPIKey = settingsStore.whisperAPIKey
        whisperModel = settingsStore.whisperModel
        freeSTTModel = settingsStore.freeSTTModel
        localSTTModel = settingsStore.localSTTModel
        multimodalLLMBaseURL = settingsStore.multimodalLLMBaseURL
        multimodalLLMAPIKey = settingsStore.multimodalLLMAPIKey
        multimodalLLMModel = settingsStore.multimodalLLMModel
        aliCloudAPIKey = settingsStore.aliCloudAPIKey
        doubaoAppID = settingsStore.doubaoAppID
        doubaoAccessToken = settingsStore.doubaoAccessToken
        doubaoResourceID = settingsStore.doubaoResourceID

        llmProvider = settingsStore.llmProvider
        llmRemoteProvider = settingsStore.llmRemoteProvider
        llmBaseURL = settingsStore.llmBaseURL(for: settingsStore.llmRemoteProvider)
        llmModel = settingsStore.llmModel(for: settingsStore.llmRemoteProvider)
        llmAPIKey = settingsStore.llmAPIKey(for: settingsStore.llmRemoteProvider)
        ollamaBaseURL = settingsStore.ollamaBaseURL
        ollamaModel = settingsStore.ollamaModel

        permissions = PrivacyGuard.snapshots()
    }

    var canGoBack: Bool { currentStep != .language }
    var isLastStep: Bool { currentStep == visibleSteps.last }
    var visibleSteps: [Step] {
        if sttProvider == .multimodalLLM {
            return Step.allCases.filter { step in
                step != .llmProvider && step != .llmConfig
            }
        }

        return Step.allCases
    }
    var isSkippable: Bool {
        switch currentStep {
        case .language, .sttConfig, .llmConfig, .permissions:
            return true
        case .sttProvider, .llmProvider, .shortcuts:
            return false
        }
    }

    var allRequiredPermissionsGranted: Bool {
        let required = PrivacyGuard.requiredPermissionIDs(settingsStore: settingsStore)
        return required.allSatisfy { id in
            permissions.first(where: { $0.id == id })?.isGranted ?? false
        }
    }

    func goBack() {
        guard canGoBack else { return }
        let previousStep = adjacentStep(offset: -1) ?? .language
        stepDirection = -1
        withAnimation(.easeInOut(duration: 0.22)) {
            currentStep = previousStep
        }
    }

    func advance() {
        saveCurrentStepSettings()
        if isLastStep {
            complete()
        } else {
            let nextStep = adjacentStep(offset: 1) ?? .shortcuts
            stepDirection = 1
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStep = nextStep
            }
        }
    }

    func skip() {
        if isLastStep {
            complete()
        } else {
            let nextStep = adjacentStep(offset: 1) ?? .shortcuts
            stepDirection = 1
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStep = nextStep
            }
        }
    }

    /// Marks onboarding as complete without triggering the completion callback.
    /// Used when the window is closed externally (e.g., user clicks the close button).
    func skipWithoutAnimation() {
        settingsStore.isOnboardingCompleted = true
    }

    func selectOllama() {
        llmProvider = .ollama
    }

    func selectLLMRemoteProvider(_ provider: LLMRemoteProvider) {
        llmProvider = .openAICompatible
        llmRemoteProvider = provider
        llmBaseURL = settingsStore.llmBaseURL(for: provider)
        llmAPIKey = settingsStore.llmAPIKey(for: provider)
        llmModel = settingsStore.llmModel(for: provider)
    }

    func setLanguage(_ language: AppLanguage) {
        appLanguage = language
        settingsStore.appLanguage = language
        AppLocalization.shared.setLanguage(language)
    }

    func refreshPermissions() {
        permissions = PrivacyGuard.snapshots()
    }

    func requestPermission(_ id: PrivacyGuard.PermissionID) {
        guard !requestingPermissions.contains(id) else { return }
        requestingPermissions.insert(id)
        Task {
            await PrivacyGuard.requestPermission(id)
            refreshPermissions()
            requestingPermissions.remove(id)
        }
    }

    private func saveCurrentStepSettings() {
        switch currentStep {
        case .language:
            settingsStore.appLanguage = appLanguage
            AppLocalization.shared.setLanguage(appLanguage)
        case .sttProvider:
            settingsStore.sttProvider = sttProvider
        case .sttConfig:
            switch sttProvider {
            case .freeModel:
                settingsStore.freeSTTModel = freeSTTModel
            case .whisperAPI:
                settingsStore.whisperBaseURL = whisperBaseURL
                settingsStore.whisperAPIKey = whisperAPIKey
                settingsStore.whisperModel = whisperModel
            case .localModel:
                settingsStore.localSTTModel = localSTTModel
            case .multimodalLLM:
                settingsStore.multimodalLLMBaseURL = multimodalLLMBaseURL
                settingsStore.multimodalLLMAPIKey = multimodalLLMAPIKey
                settingsStore.multimodalLLMModel = multimodalLLMModel
            case .aliCloud:
                settingsStore.aliCloudAPIKey = aliCloudAPIKey
            case .doubaoRealtime:
                settingsStore.doubaoAppID = doubaoAppID
                settingsStore.doubaoAccessToken = doubaoAccessToken
                settingsStore.doubaoResourceID = doubaoResourceID
            case .appleSpeech:
                break
            }
        case .llmProvider:
            settingsStore.llmProvider = llmProvider
            if llmProvider == .openAICompatible {
                settingsStore.llmRemoteProvider = llmRemoteProvider
            }
        case .llmConfig:
            if llmProvider == .openAICompatible {
                settingsStore.setLLMBaseURL(llmBaseURL, for: llmRemoteProvider)
                settingsStore.setLLMAPIKey(llmAPIKey, for: llmRemoteProvider)
                settingsStore.setLLMModel(llmModel, for: llmRemoteProvider)
            } else {
                settingsStore.ollamaBaseURL = ollamaBaseURL
                settingsStore.ollamaModel = ollamaModel
            }
        case .permissions, .shortcuts:
            break
        }
    }

    private func complete() {
        settingsStore.isOnboardingCompleted = true
        onComplete()
    }

    private func adjacentStep(offset: Int) -> Step? {
        let steps = visibleSteps
        guard let index = steps.firstIndex(of: currentStep) else {
            if offset > 0 {
                return steps.first(where: { $0.rawValue > currentStep.rawValue }) ?? steps.last
            }
            return steps.last(where: { $0.rawValue < currentStep.rawValue }) ?? steps.first
        }

        let nextIndex = index + offset
        guard steps.indices.contains(nextIndex) else { return nil }
        return steps[nextIndex]
    }
}
