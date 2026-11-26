import AppKit
import Foundation

extension AppCoordinator {
    /// Wires the switch to Typeflux Classic and schedules the one-time introduction (host only).
    func startClassicSwitch(onboardingCompletedBeforeLaunch: Bool, needsOnboarding: Bool) {
        let settingsStore = di.settingsStore
        ClassicSwitchController.shared.stopFeatureProcesses = { [weak self] in
            await self?.prepareForTermination() ?? false
        }
        ClassicSwitchWindowController.shared.appearanceMode = { [weak settingsStore] in
            settingsStore?.appearanceMode ?? .system
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let coordinator = ClassicIntroCoordinator(
            store: ClassicIntroStore(defaults: settingsStore.defaults),
            currentVersion: currentVersion,
            isClassicAvailable: { await ClassicSwitchController.shared.refreshAvailability() },
            present: { [weak self] in self?.presentClassicIntro() }
        )
        classicIntroCoordinator = coordinator
        coordinator.launch(onboardingCompletedBeforeLaunch: onboardingCompletedBeforeLaunch, needsOnboarding: needsOnboarding)
    }

    private func presentClassicIntro() {
        let controller = ClassicIntroWindowController(
            appearanceMode: di.settingsStore.appearanceMode,
            canSwitch: ClassicSwitchController.shared.isAvailable,
            onSwitch: { ClassicSwitchWindowController.shared.present() }
        )
        classicIntroWindowController = controller
        controller.show()
    }
}
