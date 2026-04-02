import AppKit
import Foundation
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case language = 0
        case models = 1
        case permissions = 2
        case shortcuts = 3

        var stepLabel: String {
            switch self {
            case .language: return L("onboarding.step.language")
            case .models: return L("onboarding.step.models")
            case .permissions: return L("onboarding.step.permissions")
            case .shortcuts: return L("onboarding.step.shortcuts")
            }
        }
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
    var isLastStep: Bool { currentStep == .shortcuts }
    var isSkippable: Bool { currentStep == .models || currentStep == .shortcuts }

    var allRequiredPermissionsGranted: Bool {
        let required = PrivacyGuard.requiredPermissionIDs(settingsStore: settingsStore)
        return required.allSatisfy { id in
            permissions.first(where: { $0.id == id })?.isGranted ?? false
        }
    }

    func goBack() {
        guard canGoBack else { return }
        stepDirection = -1
        withAnimation(.easeInOut(duration: 0.22)) {
            currentStep = Step(rawValue: currentStep.rawValue - 1) ?? .language
        }
    }

    func advance() {
        saveCurrentStepSettings()
        if isLastStep {
            complete()
        } else {
            stepDirection = 1
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStep = Step(rawValue: currentStep.rawValue + 1) ?? .shortcuts
            }
        }
    }

    func skip() {
        complete()
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
        case .models:
            settingsStore.sttProvider = sttProvider
            settingsStore.whisperBaseURL = whisperBaseURL
            settingsStore.whisperAPIKey = whisperAPIKey
            settingsStore.whisperModel = whisperModel
            settingsStore.localSTTModel = localSTTModel
            settingsStore.multimodalLLMBaseURL = multimodalLLMBaseURL
            settingsStore.multimodalLLMAPIKey = multimodalLLMAPIKey
            settingsStore.multimodalLLMModel = multimodalLLMModel
            settingsStore.aliCloudAPIKey = aliCloudAPIKey
            settingsStore.doubaoAppID = doubaoAppID
            settingsStore.doubaoAccessToken = doubaoAccessToken
            settingsStore.doubaoResourceID = doubaoResourceID
            settingsStore.llmProvider = llmProvider
            settingsStore.ollamaBaseURL = ollamaBaseURL
            settingsStore.ollamaModel = ollamaModel
            if llmProvider == .openAICompatible {
                settingsStore.llmRemoteProvider = llmRemoteProvider
                settingsStore.setLLMBaseURL(llmBaseURL, for: llmRemoteProvider)
                settingsStore.setLLMAPIKey(llmAPIKey, for: llmRemoteProvider)
                settingsStore.setLLMModel(llmModel, for: llmRemoteProvider)
            }
        case .permissions, .shortcuts:
            break
        }
    }

    private func complete() {
        settingsStore.isOnboardingCompleted = true
        onComplete()
    }
}
