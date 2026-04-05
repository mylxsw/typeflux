import AppKit
import ApplicationServices

DevLauncher.relaunchAsAppBundleIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appCoordinator: AppCoordinator?
    private var languageObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_: Notification) {
        let settingsStore = SettingsStore()
        AppLocalization.shared.setLanguage(settingsStore.appLanguage)
        AppAppearance.apply(settingsStore.appearanceMode)
        AppMenuController.install()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                AppMenuController.install()
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                AppAppearance.apply(settingsStore.appearanceMode)
            }
        }
        appCoordinator = AppCoordinator()
        appCoordinator?.start()
    }

    func applicationWillTerminate(_: Notification) {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        appCoordinator?.stop()
    }
}
