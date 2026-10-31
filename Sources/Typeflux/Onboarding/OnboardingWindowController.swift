import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject {
    static let windowWidth: CGFloat = 960
    static let windowHeight: CGFloat = 664

    private(set) var window: NSWindow?
    private(set) var viewModel: OnboardingViewModel?
    private var onCompleteHandler: (() -> Void)?

    func bringToFront() {
        if let window {
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(
        settingsStore: SettingsStore,
        historyStore: HistoryStore? = nil,
        resume: Bool = false,
        localModelManager: LocalModelManager? = nil,
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor? = nil,
        onComplete: @escaping () -> Void
    ) {
        if let window {
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        onCompleteHandler = onComplete

        let viewModel = OnboardingViewModel(
            settingsStore: settingsStore,
            localModelManager: localModelManager,
            analyticsReporter: analyticsReporter,
            permissionStatusAnalyticsMonitor: permissionStatusAnalyticsMonitor
        ) { [weak self] in
            self?.handleComplete()
        }
        if let historyStore {
            viewModel.historyStore = historyStore
            viewModel.configurationModel = StudioViewModel(
                settingsStore: settingsStore, historyStore: historyStore, initialSection: .models,
                localModelManager: localModelManager ?? LocalModelManager(),
                notificationService: notificationService, modelLibrary: viewModel.modelLibrary
            )
        }
        if resume { viewModel.resumeDeferredSetup() }

        let view = OnboardingView(
            viewModel: viewModel,
            appearanceMode: settingsStore.appearanceMode
        )
        let hosting = NSHostingView(rootView: view
            .interfaceStyle(following: InterfaceStyleObserver(settings: settingsStore))
            .frame(width: Self.windowWidth, height: Self.windowHeight)
            // This full-size content view already includes the title bar. Applying
            // its safe-area inset again would push the fixed-size root below the window.
            .ignoresSafeArea())
        // Animated page transitions must never enlarge this fixed-size wizard.
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("onboarding.window.title")
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)

        self.viewModel = viewModel
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleComplete() {
        let handler = onCompleteHandler
        onCompleteHandler = nil

        // Remove delegate before closing to avoid re-entrant delegate calls
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
        }
        window?.delegate = nil
        window?.close()
        window = nil
        viewModel?.languageTestTask?.cancel()
        viewModel?.cloudModel.endSession()
        viewModel = nil

        handler?()
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        // User closed the window manually without completing onboarding
        // Mark it complete so it doesn't show again, then call the handler
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
        }
        if onCompleteHandler != nil {
            viewModel?.skipWithoutAnimation()
            handleComplete()
        }
    }
}
