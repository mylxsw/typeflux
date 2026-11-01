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

    func refreshSetup() {
        modelLibrary.reloadFeaturePreferences()
        setupRevision += 1
        updateVoicePractice()
    }

    var languageConfigurationSignature: String {
        let value = settingsStore.textLLMConfiguration()
        let data = [modelLibrary.rewriteReference, value.baseURL, value.model, value.apiKey,
                    String(describing: value.effectiveAPIStyle)].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func updateVoicePractice() {
        guard currentStep == .try, !voicePracticeText.isEmpty, let historyStore,
              let began = voicePracticeBeganAt else { return }
        voicePracticeSucceeded = historyStore.list(limit: 5, offset: 0, searchQuery: nil).contains { record in
            guard record.date >= began, record.transcriptionStatus == .succeeded,
                  record.applyStatus == .succeeded,
                  let text = record.postProcessedText ?? record.transcriptText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return voicePracticeText.contains(text)
        }
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
        } else if settingsStore.sttProvider == .localModel, speechConfigured {
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
        let impacts = requiredPermissionIDs.filter { id in
            permissions.first(where: { $0.id == id })?.isGranted != true
        }.map { L("setup.permission.\($0.rawValue).impact") }
        return (impacts + [L("setup.permission.later")]).joined(separator: "\n\n")
    }

}
