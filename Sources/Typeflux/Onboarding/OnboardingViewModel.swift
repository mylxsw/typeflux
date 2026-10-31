import AppKit
import Combine
import Foundation
import SwiftUI

/// Service setup precedes permissions and feature guides. Skips are explicit and resumable.
@MainActor
// swiftlint:disable:next type_body_length
final class OnboardingViewModel: ObservableObject {
    typealias Step = OnboardingStep

    enum ExternalKeyboardShortcutReplacement: String, CaseIterable, Equatable {
        case rightCommand
        case rightOption

        var activationHotkey: HotkeyBinding {
            switch self {
            case .rightCommand: .rightCommandActivation
            case .rightOption: .rightOptionActivation
            }
        }

        var askHotkey: HotkeyBinding {
            switch self {
            case .rightCommand: .rightCommandAsk
            case .rightOption: .rightOptionAsk
            }
        }
    }

    lazy var routeModel = OnboardingRouteModel(session: self)
    lazy var cloudModel = OnboardingCloudModel(session: self)
    lazy var speechModel = OnboardingSpeechModel(session: self)
    lazy var llmModel = OnboardingLLMModel(session: self)
    lazy var permissionsModel = OnboardingPermissionsModel(session: self)
    lazy var shortcutsModel = OnboardingShortcutsModel(session: self)
    lazy var tryModel = OnboardingTryModel(session: self)
    var pageSubscriptions = Set<AnyCancellable>()

    @Published var currentStep: Step = .welcome
    @Published var stepDirection: Int = 1 // 1 = forward, -1 = backward
    @Published var appLanguage: AppLanguage
    /// What the user dictated into the voice guide's practice box.
    @Published var voicePracticeSucceeded = false
    @Published var voicePracticeText = ""
    @Published var serviceRoute: ServiceRoute = .cloud
    @Published var skipConfirmation: SkipTarget?
    @Published var speechSkipped = false
    @Published var aiSkipped = false
    @Published var setupRevision = 0
    @Published var isCheckingCloud = false
    @Published var cloudCheckCompleted = false
    @Published var cloudError: String?
    @Published var languageTestState: ConnectionTestState = .idle
    @Published var modelEditorDomain: StudioModelDomain?
    var requestedSetupAdvance: Step?
    var presentLogin: () -> Void = { LoginWindowController.shared.show() }
    var configurationModel: StudioViewModel? {
        didSet {
            configurationSubscription = configurationModel?.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.refreshSetup() }
            }
        }
    }
    var configurationSubscription: AnyCancellable?
    var languageTestTask: Task<Void, Never>?
    var verifiedLanguageSignature: String?
    var testingLanguageSignature: String?
    var languageConnectionProbe: @Sendable (
        RegisteredProvider, SettingsStore.TextLLMConfiguration
    ) async throws -> String = {
        try await OnboardingConnectionProbe.language(provider: $0, configuration: $1)
    }
    var setupObservers: [NSObjectProtocol] = []
    var historyStore: HistoryStore?
    var voicePracticeBeganAt: Date?
    let modelLibrary: AskModelLibrary
    let authState: AuthState

    // Permissions
    @Published var permissions: [PrivacyGuard.PermissionSnapshot] = []
    @Published var requestingPermissions: Set<PrivacyGuard.PermissionID> = []

    // Globe key (🌐) macOS keyboard setting and the external keyboard fallback
    @Published var isGlobeKeyReady: Bool = true
    @Published private(set) var auxiliaryHotkey: HotkeyBinding?
    @Published var shortcutReplacementConflict = false
    @Published private(set) var activationHotkey: HotkeyBinding
    @Published private(set) var askHotkey: HotkeyBinding?
    @Published private(set) var externalKeyboardShortcutReplacement: ExternalKeyboardShortcutReplacement?
    @Published var showShortcutReplacementAppliedAlert = false

    let settingsStore: SettingsStore
    private let globeKeyReader: GlobeKeyPreferenceReading
    let localModelManager: (any LocalSTTModelManaging)?
    private let analyticsReporter: AnalyticsEventReporting
    private let permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor?
    private let onboardingStartedAt: Date
    private let now: () -> Date
    private var didReportTerminalEvent = false
    let onComplete: () -> Void

    init(
        settingsStore: SettingsStore,
        authState: AuthState? = nil,
        modelLibrary: AskModelLibrary? = nil,
        globeKeyReader: GlobeKeyPreferenceReading = SystemGlobeKeyPreferenceReader(),
        localModelManager: (any LocalSTTModelManaging)? = nil,
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor? = nil,
        now: @escaping () -> Date = { Date() },
        onComplete: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.authState = authState ?? .shared
        self.modelLibrary = modelLibrary ?? AskModelLibrary(defaults: settingsStore.defaults)

        self.globeKeyReader = globeKeyReader
        self.localModelManager = localModelManager
        self.analyticsReporter = analyticsReporter
        self.permissionStatusAnalyticsMonitor = permissionStatusAnalyticsMonitor
        self.now = now
        onboardingStartedAt = now()
        self.onComplete = onComplete

        appLanguage = settingsStore.appLanguage
        permissions = PrivacyGuard.snapshots()
        isGlobeKeyReady = globeKeyReader.isReadyForHotkey
        let storedActivationHotkey = settingsStore.activationHotkey ?? .defaultActivation
        let storedAskHotkey = settingsStore.askHotkey
        auxiliaryHotkey = settingsStore.auxiliaryHotkey
        activationHotkey = storedActivationHotkey
        askHotkey = storedAskHotkey
        externalKeyboardShortcutReplacement = Self.detectExternalKeyboardShortcutReplacement(
            activationHotkey: storedActivationHotkey,
            askHotkey: storedAskHotkey
        )
        observePageModels()
        setupObservers.append(SettingsChangeObserver.observe { [weak self] in self?.refreshSetup() })
        for name in [Notification.Name.localModelDownloadProgressDidChange, .authDidLogin, .historyStoreDidChange] {
            setupObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshSetup() }
            })
        }
    }

    deinit {
        languageTestTask?.cancel()
        setupObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Marks onboarding as complete without triggering the completion callback.
    /// Used when the window is closed externally (e.g., user clicks the close button).
    func skipWithoutAnimation() {
        reportAbandonedIfNeeded()
        settingsStore.onboardingSpeechDeferred = speechSkipped || !speechConfigured
        settingsStore.onboardingAIDeferred = aiSkipped || !languageConfigured
        if !aiSkipped && languageConfigured { settingsStore.applyDefaultPersonaIfLLMConfigured() }
        settingsStore.isOnboardingCompleted = true
    }

    // MARK: - Guides

    func shortcuts(for feature: OnboardingFeature) -> [OnboardingShortcut] {
        feature.shortcuts(settingsStore: settingsStore)
    }

    var didPracticeVoice: Bool {
        voicePracticeSucceeded
    }

    // MARK: - Permissions

    var requiredPermissionIDs: [PrivacyGuard.PermissionID] {
        guard !speechSkipped && speechConfigured else { return [.accessibility] }
        return OnboardingFeature.requiredPermissionIDs(settingsStore: settingsStore)
    }

    var requiredPermissions: [PrivacyGuard.PermissionSnapshot] {
        requiredPermissionIDs.compactMap { id in permissions.first { $0.id == id } }
    }

    var missingPermissionCount: Int {
        requiredPermissionIDs.filter { id in !(permissions.first { $0.id == id }?.isGranted ?? false) }.count
    }

    var allRequiredPermissionsGranted: Bool {
        missingPermissionCount == 0
    }

    /// Voice input cannot start while macOS keeps 🌐 for itself, unless another key replaces it.
    var needsGlobeKeySetup: Bool {
        !speechSkipped && speechConfigured && !voiceHotkeyReady
    }

    func refreshPermissions() {
        permissions = PrivacyGuard.snapshots()
    }

    func requestPermission(_ id: PrivacyGuard.PermissionID) {
        guard !requestingPermissions.contains(id) else { return }
        requestingPermissions.insert(id)
        // In-app system dialogs take focus away; reactivate once they are dismissed.
        let willShowInAppDialog = PrivacyGuard.willShowInAppDialog(for: id)
        Task {
            await PrivacyGuard.requestPermission(id)
            refreshPermissions()
            permissionStatusAnalyticsMonitor?.observe(permissions)
            requestingPermissions.remove(id)
            if willShowInAppDialog {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Language

    func setLanguage(_ language: AppLanguage) {
        appLanguage = language
        settingsStore.appLanguage = language
        AppLocalization.shared.setLanguage(language)
    }

    // MARK: - Shortcuts

    /// The keys the welcome screen shows for each verb, read from the user's settings.
    var launcherHotkey: HotkeyBinding? {
        settingsStore.askHotkey
    }

    var ringHotkey: HotkeyBinding? {
        settingsStore.actionHotkeys[.ring]
    }

    func refreshGlobeKeyState() {
        auxiliaryHotkey = settingsStore.auxiliaryHotkey
        isGlobeKeyReady = globeKeyReader.isReadyForHotkey
    }

    func useExternalKeyboardShortcutReplacement(_ replacement: ExternalKeyboardShortcutReplacement) {
        guard updateAuxiliaryForReplacement(
            activation: replacement.activationHotkey, ask: replacement.askHotkey
        ) else { return }
        activationHotkey = replacement.activationHotkey
        askHotkey = replacement.askHotkey
        externalKeyboardShortcutReplacement = replacement
        settingsStore.activationHotkey = replacement.activationHotkey
        settingsStore.askHotkey = replacement.askHotkey
        showShortcutReplacementAppliedAlert = true
    }

    func restoreDefaultFNShortcuts() {
        guard updateAuxiliaryForReplacement(activation: .defaultActivation, ask: .defaultAsk) else { return }
        activationHotkey = .defaultActivation
        askHotkey = .defaultAsk
        externalKeyboardShortcutReplacement = nil
        settingsStore.activationHotkey = .defaultActivation
        settingsStore.askHotkey = .defaultAsk
        showShortcutReplacementAppliedAlert = true
    }

    private func updateAuxiliaryForReplacement(activation: HotkeyBinding, ask: HotkeyBinding) -> Bool {
        let previous = settingsStore.auxiliaryHotkey
        let standardBindings = [63, 54, 61].map { HotkeyBinding.auxiliaryChord(baseKeyCode: $0) }
        let followsPreset = previous.map { value in standardBindings.contains { $0.conflicts(with: value) } } ?? false
        let next = followsPreset ? HotkeyBinding.auxiliaryChord(baseKeyCode: activation.keyCode) : previous
        let existing = [settingsStore.personaHotkey, settingsStore.historyHotkey].compactMap { $0 }
        let conflicts = existing.contains { $0.conflicts(with: activation) || $0.conflicts(with: ask) }
            || next.map { candidate in
                ([activation, ask] + existing).contains { $0.conflicts(with: candidate) }
            } == true
        guard !conflicts else {
            shortcutReplacementConflict = true
            return false
        }
        settingsStore.auxiliaryHotkey = next
        auxiliaryHotkey = next
        return true
    }

    static let keyboardSystemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )!

    func openKeyboardSystemSettings() {
        NSWorkspace.shared.open(Self.keyboardSystemSettingsURL)
    }

    // MARK: - Completion

    func complete() {
        guard !didReportTerminalEvent else { return }
        didReportTerminalEvent = true
        let duration = max(0, Int(now().timeIntervalSince(onboardingStartedAt)))
        analyticsReporter.report(
            eventName: "onboarding_completed",
            properties: [
                "duration_seconds": "\(duration)",
                "missing_permissions": "\(missingPermissionCount)",
                "practiced_voice": "\(didPracticeVoice)"
            ]
        )
        if !aiSkipped && languageConfigured { settingsStore.applyDefaultPersonaIfLLMConfigured() }
        settingsStore.onboardingSpeechDeferred = speechSkipped || !speechConfigured
        settingsStore.onboardingAIDeferred = aiSkipped || !languageConfigured
        settingsStore.applyNewUserClipboardDefaults()
        settingsStore.isOnboardingCompleted = true
        onComplete()
    }

    func reportCurrentStepCompleted(skipped: Bool) {
        analyticsReporter.report(
            eventName: "onboarding_step_completed",
            properties: ["step": currentStep.analyticsName, "skipped": "\(skipped)"]
        )
    }

    private func reportAbandonedIfNeeded() {
        guard !didReportTerminalEvent else { return }
        didReportTerminalEvent = true
        analyticsReporter.report(
            eventName: "onboarding_abandoned",
            properties: ["last_step": currentStep.analyticsName]
        )
    }

    private static func detectExternalKeyboardShortcutReplacement(
        activationHotkey: HotkeyBinding,
        askHotkey: HotkeyBinding?
    ) -> ExternalKeyboardShortcutReplacement? {
        ExternalKeyboardShortcutReplacement.allCases.first { replacement in
            activationHotkey.signature == replacement.activationHotkey.signature
                && askHotkey?.signature == replacement.askHotkey.signature
        }
    }
}
