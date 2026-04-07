import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject {
    static let windowWidth: CGFloat = 980
    static let windowHeight: CGFloat = 780

    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?
    private var onCompleteHandler: (() -> Void)?

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(settingsStore: SettingsStore, onComplete: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        onCompleteHandler = onComplete

        let viewModel = OnboardingViewModel(settingsStore: settingsStore) { [weak self] in
            self?.handleComplete()
        }

        let view = OnboardingView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = L("onboarding.window.title")
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)

        self.viewModel = viewModel
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleComplete() {
        let handler = onCompleteHandler
        onCompleteHandler = nil

        // Remove delegate before closing to avoid re-entrant delegate calls
        window?.delegate = nil
        window?.close()
        window = nil
        viewModel = nil

        handler?()
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        // User closed the window manually without completing onboarding
        // Mark it complete so it doesn't show again, then call the handler
        if onCompleteHandler != nil {
            viewModel?.skipWithoutAnimation()
            handleComplete()
        }
    }
}
