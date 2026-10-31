import AppKit
import AVFoundation
import Foundation
import Speech

extension WorkflowController {
    /// Resolve model setup before asking for access to the microphone.
    func showMissingSpeechSetupIfNeeded(requiresAccessibility: Bool = true) -> Bool {
        if showMissingSpeechModelSetupIfNeeded() { return true }
        guard PrivacyGuard.isRunningInAppBundle else { return false }
        let missing: PrivacyGuard.PermissionID? = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            ? .microphone : requiresAccessibility && !PrivacyGuard.isAccessibilityGranted() ? .accessibility
            : (settingsStore.sttProvider == .appleSpeech || settingsStore.useAppleSpeechFallback)
            && SFSpeechRecognizer.authorizationStatus() != .authorized ? .speechRecognition : nil
        guard let missing else { return false }
        Task { @MainActor [weak self] in
            let actionTitle = PrivacyGuard.snapshots().first { $0.id == missing }?.actionTitle ?? missing.title
            self?.overlayController.showFailureWithActions(message: missing.summary, actions: [
                OverlayFailureAction(title: actionTitle, isRetry: false, handler: {
                    Task { await PrivacyGuard.requestPermission(missing) }
                })
            ])
        }
        return true
    }

    private func showMissingSpeechModelSetupIfNeeded() -> Bool {
        let provider = settingsStore.sttProvider
        // Cloud keeps its existing local fallback and account recovery behavior.
        if provider == .typefluxOfficial { return false }
        // Ordinary local preparation keeps its existing progress panel. An explicit
        // deferral offers the same model editor used during first-run setup.
        if provider == .localModel, !settingsStore.onboardingSpeechDeferred { return false }
        guard let reason = FeatureSetupStatus.speechReason(
            settings: settingsStore,
            loggedIn: false,
            cloudAllowed: false,
            localAvailable: localModelManager?.isModelAvailable(settingsStore.localSTTModel) ?? false,
            googleAuthorized: GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable()
        ) else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            overlayController.showFailureWithActions(message: L("setup.speech.required", reason),
                                                     actions: speechSetupActions())
        }
        return true
    }

    @MainActor
    func speechSetupActions() -> [OverlayFailureAction] {
        var actions = [OverlayFailureAction(title: L("setup.speech.configure"), isRetry: false,
                                            trailingSystemImage: "gearshape", handler: { [weak self] in
                                                guard let self else { return }
                                                SettingsWindowController.shared.show(
                                                    settingsStore: settingsStore,
                                                    historyStore: historyStore,
                                                    initialSection: .models,
                                                    initialModelDomain: .stt
                                                )
                                            })]
        if !billingAuth().isLoggedIn {
            actions.append(OverlayFailureAction(title: L("setup.cloud.signIn"), isRetry: false, style: .secondary,
                                                handler: { LoginWindowController.shared.show() }))
        }
        return actions
    }
}
