import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    var modelLibrary: AskModelLibrary?
    /// The clipboard history, for Launcher → Clipboard's data usage.
    var clipboardHistoryStore: ClipboardHistoryStore?
    private var settingsStore: SettingsStore?
    private(set) var window: NSWindow?
    private(set) var viewModel: StudioViewModel?
    private var appearanceObserver: NSObjectProtocol?

    override init() {
        super.init()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAppearance()
            }
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    func show(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        initialSection: StudioSection = .settings,
        initialModelDomain: StudioModelDomain? = nil,
        launcherPane: LauncherSettingsPane? = nil,
        presentFeedback: Bool = false,
        modelManager: OllamaModelManaging = OllamaLocalModelManager(),
        localModelManager: LocalSTTModelManaging = LocalModelManager(),
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        onRetryHistory: @escaping (HistoryRecord) -> Void = { _ in }
    ) {
        self.settingsStore = settingsStore

        Task { await AuthState.shared.refreshTokenIfNeeded() }

        if let window {
            if let launcherPane {
                viewModel?.navigate(toLauncherPane: launcherPane)
            } else {
                viewModel?.navigate(to: initialSection)
            }
            if let initialModelDomain {
                viewModel?.selectModelPageTab(ModelPageTab(domain: initialModelDomain))
                viewModel?.setModelDomain(initialModelDomain)
            }
            if presentFeedback {
                viewModel?.directFeedbackRequestID = UUID()
            }
            refreshAppearance()
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AuthState.shared.refreshProfileIfNeeded()
            return
        }

        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: initialSection,
            onRetryHistory: onRetryHistory,
            modelManager: modelManager,
            localModelManager: localModelManager,
            notificationService: notificationService,
            modelLibrary: modelLibrary
        )
        if let initialModelDomain {
            viewModel.selectModelPageTab(ModelPageTab(domain: initialModelDomain))
            viewModel.setModelDomain(initialModelDomain)
        }
        AppLocalization.shared.setLanguage(viewModel.appLanguage)
        if presentFeedback { viewModel.directFeedbackRequestID = UUID() }
        let view = StudioView(viewModel: viewModel, launcherPane: launcherPane ?? .basics)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: StudioTheme.Layout.settingsWindowWidth,
                height: StudioTheme.Layout.settingsWindowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("window.voiceStudio")
        window.center()
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.settings.toolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .visible
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        let minimumWindowSize = NSSize(
            width: StudioTheme.Layout.settingsWindowMinWidth,
            height: StudioTheme.Layout.settingsWindowMinHeight
        )
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)

        self.viewModel = viewModel
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        window.contentMinSize = minimumWindowSize
        NSApp.activate(ignoringOtherApps: true)
        AuthState.shared.refreshProfileIfNeeded()
    }

    private func refreshAppearance() {
        guard let settingsStore else { return }
        window?.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
            // Detach the hosting tree so SwiftUI tasks and native search monitors stop immediately.
            window.contentView = nil
        }
        window = nil
        viewModel = nil
    }
}
