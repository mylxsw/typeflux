import AppKit
import SwiftUI

private final class TransparentSettingsHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    var modelLibrary: AskModelLibrary?
    private var settingsStore: SettingsStore?
    private var window: NSWindow?
    private var viewModel: StudioViewModel?
    private var languageObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    override init() {
        super.init()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window?.title = L("window.voiceStudio")
            }
        }
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

    func show(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        initialSection: StudioSection = .settings,
        initialModelDomain: StudioModelDomain? = nil,
        launcherPane: LauncherSettingsPane? = nil,
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
            if let initialModelDomain { viewModel?.setModelDomain(initialModelDomain) }
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
        if let initialModelDomain { viewModel.setModelDomain(initialModelDomain) }
        AppLocalization.shared.setLanguage(viewModel.appLanguage)
        let view = StudioView(viewModel: viewModel, launcherPane: launcherPane ?? .basics)
        let hosting = TransparentSettingsHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: StudioTheme.Layout.settingsWindowWidth,
                height: StudioTheme.Layout.settingsWindowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("window.voiceStudio")
        window.center()
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
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
        }
        window = nil
        viewModel = nil
    }
}
