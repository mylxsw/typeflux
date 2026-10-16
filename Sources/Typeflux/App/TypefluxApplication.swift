import AppKit
import ApplicationServices

public enum TypefluxApplication {
    public static func run() {
        // Shared by SwiftPM and Xcode launchers, before relaunch or application DI.
        if let code = NativeSystemWorkerCommand.handleInvocation(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        DevLauncher.relaunchAsAppBundleIfNeeded()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appCoordinator: AppCoordinator?
    private var languageObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private let termination = AppTerminationBarrier()

    func applicationDidFinishLaunching(_: Notification) {
        let settingsStore = SettingsStore()
        AppLocalization.shared.setLanguage(settingsStore.appLanguage)
        AppAppearance.apply(settingsStore.appearanceMode)
        AppMenuController.install()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppMenuController.install()
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppAppearance.apply(settingsStore.appearanceMode)
            }
        }
        appCoordinator = AppCoordinator()
        appCoordinator?.start()
        if ComponentGalleryAccess.opensAtLaunch() {
            Task { @MainActor in ComponentGalleryWindowController.shared.show() }
        }
    }

    func application(_: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            await AppLoginURLRouter.handle(
                urls, login: AuthState.shared.webLoginCoordinator,
                isLoggedIn: { AuthState.shared.isLoggedIn },
                showLogin: { LoginWindowController.shared.showWebLoginFailure() },
                handleBilling: { await BillingReturnLink.handle(auth: .shared) }
            )
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appCoordinator else { return .terminateNow }
        return termination.begin {
            if appCoordinator.hasScreenRecording {
                await appCoordinator.finishScreenRecordingForTermination()
            }
            await appCoordinator.prepareForTermination()
        } reply: {
            sender.reply(toApplicationShouldTerminate: true)
        }
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
