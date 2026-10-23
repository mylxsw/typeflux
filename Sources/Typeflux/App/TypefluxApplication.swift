import AppKit
import ApplicationServices

public enum TypefluxApplication {
    @MainActor
    public static func run() {
        // Shared by SwiftPM and Xcode launchers, before relaunch or application DI.
        if let code = NativeSystemWorkerCommand.handleInvocation(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        do { try FeatureProcess.install(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch { exit(64) }
        if FeatureProcess.role == .host { DevLauncher.relaunchAsAppBundleIfNeeded() }

        if FeatureProcess.role == .host { TypefluxDataDirectories.prepare() }

        let app = NSApplication.shared
        if FeatureProcess.role == .background {
            app.setActivationPolicy(.prohibited)
            FeatureBackgroundRuntime.shared.start()
            app.run()
            return
        }
        let settingsStore = SettingsStore()
        let delegate = AppDelegate(settingsStore: settingsStore)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // Restore the chosen icon before AppKit registers the app with the Dock.
        AppIconController.apply(settingsStore.appIconStyle)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: SettingsStore
    private var appCoordinator: AppCoordinator?
    private var languageObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var appIconObserver: NSObjectProtocol?
    private let termination = AppTerminationBarrier()
    private let responsiveness = MainThreadHangMonitor()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        responsiveness.start()
        let settingsStore = self.settingsStore
        AppLocalization.shared.setLanguage(settingsStore.appLanguage)
        AppAppearance.apply(settingsStore.appearanceMode)
        AppIconController.apply(settingsStore.appIconStyle)
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
        appIconObserver = NotificationCenter.default.addObserver(
            forName: .appIconStyleDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppIconController.apply(settingsStore.appIconStyle)
            }
        }
        appCoordinator = AppCoordinator()
        appCoordinator?.start()
        if CommandLine.arguments.contains("--shortcut-diagnostics-window") {
            ShortcutLatencyWindowController.shared.show()
        }
        if ComponentGalleryAccess.opensAtLaunch() {
            Task { @MainActor in ComponentGalleryWindowController.shared.show() }
        }
    }

    func application(_: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if !FeatureProcess.owns(.host) {
                if let data = try? JSONEncoder().encode(urls) { FeatureProcess.send(.init(destination: .host, action: "loginURLs", payload: data)) }
                return
            }
            await AppLoginURLRouter.handle(
                urls, login: AuthState.shared.webLoginCoordinator,
                isLoggedIn: { AuthState.shared.isLoggedIn },
                showLogin: { LoginWindowController.shared.showWebLoginFailure() },
                handleBilling: { await BillingReturnLink.handle(auth: .shared) }
            )
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !FeatureProcess.owns(.host) { FeatureProcess.send(.init(destination: .host, action: "quit")); return .terminateCancel }
        guard let appCoordinator else { return .terminateNow }
        return termination.beginChecked {
            if appCoordinator.hasScreenRecording {
                await appCoordinator.finishScreenRecordingForTermination()
            }
            return await appCoordinator.prepareForTermination()
        } reply: { confirmed in
            sender.reply(toApplicationShouldTerminate: confirmed)
        }
    }

    func applicationWillTerminate(_: Notification) {
        responsiveness.stop()
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let appIconObserver {
            NotificationCenter.default.removeObserver(appIconObserver)
        }
        appCoordinator?.stop()
    }
}
