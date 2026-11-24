import AppKit
import Foundation
import os

extension Notification.Name {
    /// Posted after account-backed Typeflux Cloud model defaults have been
    /// applied to ``SettingsStore``.
    static let cloudAccountModelDefaultsDidApply = Notification.Name(
        "CloudLoginSyncCoordinator.cloudAccountModelDefaultsDidApply"
    )
}

@MainActor
protocol CloudModelDefaultsPrompting: AnyObject {
    func confirmSwitchToCloudDefaults() -> Bool
}

@MainActor
final class CloudModelDefaultsAlertPresenter: CloudModelDefaultsPrompting {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func confirmSwitchToCloudDefaults() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = AppIconController.image(for: settingsStore.appIconStyle)
        alert.messageText = L("cloud.subscriptionSwitch.title")
        alert.informativeText = L("cloud.subscriptionSwitch.body")
        alert.addButton(withTitle: L("cloud.subscriptionSwitch.confirm"))
        alert.addButton(withTitle: L("cloud.subscriptionSwitch.keepCurrent"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Offers Cloud defaults after explicit login or checkout once the current
/// account's subscription check has settled.
@MainActor
final class CloudLoginSyncCoordinator {
    private struct Offer: Equatable {
        let generation: Int
        let speech: STTProvider
        let language: LLMProvider
        let languageRemote: LLMRemoteProvider
        let rewriteReference: String
    }

    private let settingsStore: SettingsStore
    private let authState: AuthState
    private let promptPresenter: CloudModelDefaultsPrompting
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudLoginSyncCoordinator")
    private var observers: [NSObjectProtocol] = []
    private var pendingOffer: Offer?
    private var presentingGeneration: Int?

    init(
        settingsStore: SettingsStore,
        authState: AuthState? = nil,
        promptPresenter: CloudModelDefaultsPrompting? = nil
    ) {
        self.settingsStore = settingsStore
        self.authState = authState ?? AuthState.shared
        self.promptPresenter = promptPresenter ?? CloudModelDefaultsAlertPresenter(settingsStore: settingsStore)
        let notifications: [Notification.Name] = [
            .authDidLogin, .authCheckoutSubscriptionDidBecomeEntitled, .authSubscriptionCheckDidFinish, .authDidLogout
        ]
        for name in notifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, (notification.object as? AuthState) === self.authState else { return }
                    if name == .authDidLogout {
                        self.pendingOffer = nil
                        return
                    }
                    if name != .authSubscriptionCheckDidFinish {
                        self.queueOffer()
                    }
                    guard self.pendingOffer != nil else { return }
                    Task { @MainActor [weak self] in self?.presentPendingOffer() }
                }
            })
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var currentOffer: Offer? {
        guard authState.isLoggedIn, settingsStore.isOnboardingCompleted,
              OnboardingCloudModel.activeSession == nil else { return nil }
        return Offer(generation: authState.sessionGeneration, speech: settingsStore.sttProvider,
                     language: settingsStore.llmProvider, languageRemote: settingsStore.llmRemoteProvider,
                     rewriteReference: settingsStore.rewriteModelReference)
    }

    private func queueOffer() {
        guard let offer = currentOffer, offer.generation != presentingGeneration else { return }
        pendingOffer = offer
    }

    private func presentPendingOffer() {
        guard presentingGeneration == nil, let offer = pendingOffer else { return }
        // A different account, onboarding, or a new model choice supersedes a queued offer.
        guard currentOffer == offer else {
            pendingOffer = nil
            return
        }
        guard let canUseSpeech = authState.settledCloudASRAccess else { return }
        pendingOffer = nil
        guard canUseSpeech else { return }
        let alreadyUsesCloudRewrite = settingsStore.effectiveLLMProvider == .openAICompatible
            && settingsStore.textLLMConfiguration().provider == .typefluxCloud
        guard !alreadyUsesCloudRewrite || offer.speech != .typefluxOfficial else { return }

        presentingGeneration = offer.generation
        defer {
            presentingGeneration = nil
            if pendingOffer != nil {
                Task { @MainActor [weak self] in self?.presentPendingOffer() }
            }
        }
        logger.debug("Offering Cloud defaults for speech and rewrite")
        guard promptPresenter.confirmSwitchToCloudDefaults(), currentOffer == offer else { return }
        guard authState.settledCloudASRAccess == true else {
            pendingOffer = offer
            return
        }

        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.localOptimizationEnabled = false
        settingsStore.onboardingSpeechDeferred = false
        if !alreadyUsesCloudRewrite {
            applyCloudLanguageModel()
        }
        NotificationCenter.default.post(name: .cloudAccountModelDefaultsDidApply, object: settingsStore)
        if FeatureProcess.enabled {
            settingsStore.defaults.synchronize()
            FeatureProcess.send(.init(destination: .settings, action: "cloudAccountModelDefaultsApplied"))
        }
    }

    private func applyCloudLanguageModel() {
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud
        settingsStore.defaults.set("cloud:default", forKey: "llm.profile.reference")
        settingsStore.onboardingAIDeferred = false
        settingsStore.applyDefaultPersonaIfLLMConfigured()
    }
}
