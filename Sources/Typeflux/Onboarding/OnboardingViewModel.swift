import AppKit
import Foundation
import SwiftUI

/// First-run setup: welcome → what the user wants to use → the permissions those uses need.
/// Models are not configured here: speech recognition works offline out of the box and AI is
/// connected the first time a feature needs it.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome = 0
        case goals = 1
        case permissions = 2

        var analyticsName: String {
            switch self {
            case .welcome: "welcome"
            case .goals: "goals"
            case .permissions: "permissions"
            }
        }
    }

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

    @Published var currentStep: Step = .welcome
    @Published var stepDirection: Int = 1 // 1 = forward, -1 = backward
    @Published var appLanguage: AppLanguage
    @Published private(set) var goals: Set<OnboardingGoal>

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

    private let settingsStore: SettingsStore
    private let globeKeyReader: GlobeKeyPreferenceReading
    private let localModelManager: (any LocalSTTModelManaging)?
    private let notificationService: LocalNotificationSending
    private let analyticsReporter: AnalyticsEventReporting
    private let permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor?
    private let onboardingStartedAt: Date
    private let now: () -> Date
    private var didReportTerminalEvent = false
    let onComplete: () -> Void
    private var localSTTPreparationTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        globeKeyReader: GlobeKeyPreferenceReading = SystemGlobeKeyPreferenceReader(),
        localModelManager: (any LocalSTTModelManaging)? = nil,
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor? = nil,
        now: @escaping () -> Date = { Date() },
        onComplete: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.globeKeyReader = globeKeyReader
        self.localModelManager = localModelManager
        self.notificationService = notificationService
        self.analyticsReporter = analyticsReporter
        self.permissionStatusAnalyticsMonitor = permissionStatusAnalyticsMonitor
        self.now = now
        onboardingStartedAt = now()
        self.onComplete = onComplete

        appLanguage = settingsStore.appLanguage
        goals = settingsStore.onboardingGoals.flatMap { $0.isEmpty ? nil : $0 } ?? OnboardingGoal.defaultSelection
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
    }

    deinit {
        localSTTPreparationTask?.cancel()
    }

    // MARK: - Navigation

    var visibleSteps: [Step] {
        Step.allCases
    }

    var canGoBack: Bool {
        currentStep != .welcome
    }

    var isLastStep: Bool {
        currentStep == visibleSteps.last
    }

    /// Whether the primary button can move on from the current step.
    var canAdvance: Bool {
        switch currentStep {
        case .welcome: true
        case .goals: !goals.isEmpty
        case .permissions: allRequiredPermissionsGranted
        }
    }

    func advance() {
        guard canAdvance else { return }
        reportCurrentStepCompleted(skipped: false)
        if currentStep == .goals {
            reportGoalsSelected()
            prepareSpeechModelIfNeeded()
        }
        advanceToNextStepOrComplete()
    }

    func goBack() {
        guard canGoBack, let previous = adjacentStep(offset: -1) else { return }
        stepDirection = -1
        withAnimation(.easeInOut(duration: 0.22)) {
            currentStep = previous
        }
    }

    /// Finishes setup with permissions still missing; they are asked for again when needed.
    func finishLater() {
        guard currentStep == .permissions else { return }
        reportCurrentStepCompleted(skipped: true)
        complete()
    }

    /// Marks onboarding as complete without triggering the completion callback.
    /// Used when the window is closed externally (e.g., user clicks the close button).
    func skipWithoutAnimation() {
        reportAbandonedIfNeeded()
        settingsStore.onboardingGoals = goals
        settingsStore.applyDefaultPersonaIfLLMConfigured()
        settingsStore.isOnboardingCompleted = true
    }

    // MARK: - Goals

    var orderedGoals: [OnboardingGoal] {
        OnboardingGoal.ordered(goals)
    }

    var allGoalsSelected: Bool {
        goals.count == OnboardingGoal.allCases.count
    }

    var estimatedMinutes: Int {
        goals.reduce(0) { $0 + $1.estimatedMinutes }
    }

    func toggleGoal(_ goal: OnboardingGoal) {
        if goals.contains(goal) {
            goals.remove(goal)
        } else {
            goals.insert(goal)
        }
    }

    /// Selects every goal, or goes back to the default selection when all are already picked.
    func toggleAllGoals() {
        goals = allGoalsSelected ? OnboardingGoal.defaultSelection : Set(OnboardingGoal.allCases)
    }

    // MARK: - Permissions

    var requiredPermissionIDs: [PrivacyGuard.PermissionID] {
        OnboardingGoal.requiredPermissionIDs(for: goals, settingsStore: settingsStore)
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

    /// The features each permission unlocks among the user's picks, for the chips under it.
    func goals(using permission: PrivacyGuard.PermissionID) -> [OnboardingGoal] {
        orderedGoals.filter { $0.requiredPermissions.contains(permission) || (permission == .speechRecognition && $0 == .voice) }
    }

    /// Voice input cannot start while macOS keeps 🌐 for itself, unless another key replaces it.
    var needsGlobeKeySetup: Bool {
        goals.contains(.voice) && !isGlobeKeyReady && activationHotkey.signature == HotkeyBinding.defaultActivation.signature
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

    private func complete() {
        guard !didReportTerminalEvent else { return }
        didReportTerminalEvent = true
        let duration = max(0, Int(now().timeIntervalSince(onboardingStartedAt)))
        analyticsReporter.report(
            eventName: "onboarding_completed",
            properties: [
                "duration_seconds": "\(duration)",
                "goals": orderedGoals.map(\.rawValue).joined(separator: ","),
                "missing_permissions": "\(missingPermissionCount)"
            ]
        )
        settingsStore.onboardingGoals = goals
        settingsStore.applyDefaultPersonaIfLLMConfigured()
        settingsStore.applyNewUserClipboardDefaults()
        settingsStore.isOnboardingCompleted = true
        onComplete()
    }

    private func reportCurrentStepCompleted(skipped: Bool) {
        analyticsReporter.report(
            eventName: "onboarding_step_completed",
            properties: ["step": currentStep.analyticsName, "skipped": "\(skipped)"]
        )
    }

    private func reportGoalsSelected() {
        analyticsReporter.report(
            eventName: "onboarding_goal_selected",
            properties: ["goals": orderedGoals.map(\.rawValue).joined(separator: ",")]
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

    private func advanceToNextStepOrComplete() {
        guard !isLastStep, let next = adjacentStep(offset: 1) else {
            complete()
            return
        }
        stepDirection = 1
        withAnimation(.easeInOut(duration: 0.22)) {
            currentStep = next
        }
    }

    private func adjacentStep(offset: Int) -> Step? {
        let steps = visibleSteps
        guard let index = steps.firstIndex(of: currentStep), steps.indices.contains(index + offset) else { return nil }
        return steps[index + offset]
    }

    // MARK: - Speech model

    /// Voice input uses the on-device model by default. Start fetching it in the background
    /// while the user grants permissions, unless it is bundled or already downloaded.
    private func prepareSpeechModelIfNeeded() {
        guard goals.contains(.voice),
              settingsStore.sttProvider == .localModel,
              let localModelManager,
              localSTTPreparationTask == nil
        else { return }
        let model = settingsStore.localSTTModel
        guard !localModelManager.isModelAvailable(model) else { return }
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        LocalModelDownloadProgressCenter.shared.reportDownloading(model: model, progress: 0.02)
        localSTTPreparationTask = Task { [localModelManager, notificationService] in
            do {
                try await localModelManager.prepareModel(configuration: configuration) { update in
                    LocalModelDownloadProgressCenter.shared.reportDownloading(model: model, progress: update.progress)
                }
                guard !Task.isCancelled else { return }
                LocalModelDownloadProgressCenter.shared.clear()
                await notificationService.sendLocalNotification(
                    title: L("notification.localModelReady.title"),
                    body: L("notification.localModelReady.body"),
                    identifier: "ai.gulu.app.typeflux.local-model-ready"
                )
            } catch {
                guard !Task.isCancelled else {
                    LocalModelDownloadProgressCenter.shared.clear()
                    return
                }
                NetworkDebugLogger.logError(context: "Onboarding local STT model download failed", error: error)
                LocalModelDownloadProgressCenter.shared.reportFailed(model: model, message: error.localizedDescription)
            }
        }
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
