import AppKit
import Combine
import SwiftUI

/// Floating panel used by the introduction and the switch flow, matching the update alert.
@MainActor
private func makeClassicPanel(appearanceMode: AppearanceMode) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
    panel.appearance = AppAppearance.nsAppearance(for: appearanceMode)
    return panel
}

@MainActor
private func host(_ view: some View, in panel: NSPanel) {
    let hosting = NSHostingController(rootView: AnyView(view.environment(\.locale, AppLocalization.shared.locale)))
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentViewController = hosting
    panel.setContentSize(hosting.view.fittingSize)
    panel.center()
}

/// Shows the confirmation, progress and failure states of `ClassicSwitchController`.
@MainActor
final class ClassicSwitchWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ClassicSwitchWindowController(controller: .shared)

    /// Set by the app coordinator so the panel follows the chosen appearance.
    var appearanceMode: () -> AppearanceMode = { .system }

    private let controller: ClassicSwitchController
    private var phaseObserver: AnyCancellable?

    init(controller: ClassicSwitchController) {
        self.controller = controller
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    var isPresented: Bool { window?.isVisible == true }

    /// Opens the confirmation, or brings a running switch to the front.
    func present() {
        controller.beginSwitch()
        if window == nil {
            let panel = makeClassicPanel(appearanceMode: appearanceMode())
            host(ClassicSwitchView(controller: controller), in: panel)
            panel.delegate = self
            window = panel
            phaseObserver = controller.$phase.dropFirst().sink { [weak self] phase in
                // Published fires before the value changes; act on the next turn.
                DispatchQueue.main.async { self?.phaseDidChange(phase) }
            }
        }
        guard let window else { return }
        DockVisibilityController.shared.windowDidShow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func phaseDidChange(_ phase: ClassicSwitchController.Phase) {
        guard let window else { return }
        if phase == .idle {
            window.close()
        } else if let hosting = window.contentViewController {
            window.setContentSize(hosting.view.fittingSize)
        }
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        controller.phase != .installing
    }

    func windowWillClose(_: Notification) {
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        phaseObserver = nil
        window = nil
        controller.cancel()
    }
}

/// The one-time introduction of Typeflux Classic.
@MainActor
final class ClassicIntroWindowController: NSWindowController, NSWindowDelegate {
    private var onSwitch: (() -> Void)?

    convenience init(appearanceMode: AppearanceMode, canSwitch: Bool, onSwitch: @escaping () -> Void) {
        let panel = makeClassicPanel(appearanceMode: appearanceMode)
        self.init(window: panel)
        self.onSwitch = onSwitch
        host(ClassicIntroView(
            canSwitch: canSwitch,
            onContinue: { [weak self] in self?.window?.close() },
            onSwitch: { [weak self] in
                let action = self?.onSwitch
                self?.onSwitch = nil
                self?.window?.close()
                action?()
            },
            onLearnMore: { NSWorkspace.shared.open(ClassicProductLinks.comparisonURL) }
        ), in: panel)
        panel.delegate = self
    }

    func show() {
        guard let window else { return }
        DockVisibilityController.shared.windowDidShow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        onSwitch = nil
    }
}
