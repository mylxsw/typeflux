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

    // LLM Config
    @Published var llmProvider: LLMProvider
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
            // Onboarding only shows 3 main STT options
            switch p {
            case .appleSpeech, .whisperAPI, .localModel: return p
            default: return .appleSpeech
            }
        }()
        whisperBaseURL = settingsStore.whisperBaseURL
        whisperAPIKey = settingsStore.whisperAPIKey
        whisperModel = settingsStore.whisperModel
        localSTTModel = settingsStore.localSTTModel

        llmProvider = settingsStore.llmProvider
        llmBaseURL = settingsStore.llmBaseURL
        llmModel = settingsStore.llmModel
        llmAPIKey = settingsStore.llmAPIKey
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
            settingsStore.llmProvider = llmProvider
            settingsStore.llmBaseURL = llmBaseURL
            settingsStore.llmModel = llmModel
            settingsStore.llmAPIKey = llmAPIKey
            settingsStore.ollamaBaseURL = ollamaBaseURL
            settingsStore.ollamaModel = ollamaModel
        case .permissions, .shortcuts:
            break
        }
    }

    private func complete() {
        settingsStore.isOnboardingCompleted = true
        onComplete()
    }
}
