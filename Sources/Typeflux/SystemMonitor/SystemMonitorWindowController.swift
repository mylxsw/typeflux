import AppKit
import Combine
import SwiftUI

/// What the window's views read and change; the controller applies changes to the panel.
@MainActor
final class SystemMonitorWindowModel: ObservableObject {
    @Published var settings: SystemMonitorWindowSettings
    /// A moment of accent outline, when ⌘O in the launcher points at the open window.
    @Published var flashing = false

    init(settings: SystemMonitorWindowSettings) {
        self.settings = settings
    }
}

/// The monitor's own window (⌘O in the launcher): one at a time, floating above
/// other windows by default, never taking focus from the app in use.
@MainActor
final class SystemMonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = SystemMonitorWindowController()
    static let activityMonitorURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")

    let store: SystemMonitorStore
    let model: SystemMonitorWindowModel
    private let defaults: UserDefaults
    /// Opens the launcher on the monitor, focused on a metric; set by the launcher's owner.
    var openInLauncher: (SystemMonitorMetric?) -> Void = { _ in }
    var screens: () -> [NSScreen] = { NSScreen.screens }

    private(set) var panel: SystemMonitorPanel?
    private var hosting: NSHostingView<AnyView>?
    private lazy var interfaceStyleObserver = InterfaceStyleObserver(settings: SettingsStore(defaults: defaults))
    private var client: UUID?
    private var flashTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, store: SystemMonitorStore? = nil) {
        self.defaults = defaults
        self.store = store ?? .shared
        model = SystemMonitorWindowModel(settings: .load(from: defaults))
        super.init()
        self.store.interval = model.settings.interval
    }

    var isOpen: Bool { panel?.isVisible == true }
    var settings: SystemMonitorWindowSettings { model.settings }

    /// At launch: opens the window again when it was open at quit and the user wants that.
    func restoreIfNeeded() {
        store.interval = settings.interval
        if settings.restore, settings.isOpen { show(animated: false) }
    }

    /// Opens the window, or points at it when it is open already.
    func show(sort: SystemMonitorSort? = nil, animated: Bool = true) {
        if let sort, sort != .disk { update { $0.sort = sort } }
        if isOpen {
            reveal()
            return
        }
        let panel = makePanel()
        self.panel = panel
        applyBehavior(panel)
        resize(panel, mode: settings.mode, anchor: nil)
        panel.alphaValue = animated ? 0 : settings.opacity
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = self.settings.opacity
            }
        }
        client = store.attach(.init(processes: settings.mode == .full, visible: true))
        update { $0.isOpen = true }
    }

    /// Brings the open window forward and outlines it for a moment.
    func reveal() {
        panel?.orderFrontRegardless()
        flashTask?.cancel()
        model.flashing = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.model.flashing = false
        }
    }

    func close() {
        guard let panel else { return }
        saveFrame(panel)
        panel.orderOut(nil)
        panel.delegate = nil
        self.panel = nil
        hosting = nil
        store.detach(client)
        client = nil
        update { $0.isOpen = false }
    }

    // MARK: Options

    func setMode(_ mode: SystemMonitorWindowMode) {
        guard mode != settings.mode else { return }
        let anchor = panel.map { CGPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        if let panel { saveFrame(panel) }
        update { $0.mode = mode }
        if let panel { resize(panel, mode: mode, anchor: anchor) }
        if let client { store.update(client, .init(processes: mode == .full, visible: isVisibleOnScreen)) }
    }

    func togglePinned() { update { $0.pinned.toggle() } }
    func toggleAllSpaces() { update { $0.allSpaces.toggle() } }
    func toggleRestore() { update { $0.restore.toggle() } }
    func setSort(_ sort: SystemMonitorSort) { update { $0.sort = sort } }

    func toggleMetric(_ metric: SystemMonitorMetric) {
        update { $0.toggle(metric) }
        if let panel { resize(panel, mode: settings.mode, anchor: CGPoint(x: panel.frame.minX, y: panel.frame.maxY)) }
    }

    func setInterval(_ interval: TimeInterval) {
        update { $0.interval = interval }
        store.interval = interval
    }

    func setOpacity(_ opacity: Double) {
        update { $0.opacity = opacity }
        panel?.alphaValue = opacity
    }

    func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: Self.activityMonitorURL, configuration: .init())
    }

    private func update(_ change: (inout SystemMonitorWindowSettings) -> Void) {
        var settings = model.settings
        change(&settings)
        guard settings != model.settings else { return }
        model.settings = settings
        settings.save(to: defaults)
        if let panel { applyBehavior(panel) }
    }

    // MARK: Panel

    private func makePanel() -> SystemMonitorPanel {
        let panel = SystemMonitorPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 300),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityIdentifier("system.monitor.window")
        panel.setAccessibilityTitle(L("system.monitor.title"))
        panel.onClose = { [weak self] in self?.close() }
        panel.delegate = self
        let hosting = NSHostingView(rootView: AnyView(SystemMonitorWindowView(controller: self, model: model, store: store)
            .interfaceStyle(following: interfaceStyleObserver)))
        // Measured for `fittingSize`; the controller sizes the panel itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    private func applyBehavior(_ panel: NSPanel) {
        panel.level = settings.pinned ? .floating : .normal
        panel.isFloatingPanel = settings.pinned
        panel.collectionBehavior = settings.allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.managed, .fullScreenAuxiliary, .ignoresCycle]
        if panel.isVisible { panel.alphaValue = settings.opacity }
    }

    /// Sizes the window to its content, at its saved place for the mode or kept
    /// under `anchor` (the old top left) when switching.
    private func resize(_ panel: NSPanel, mode: SystemMonitorWindowMode, anchor: CGPoint?) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let saved = settings.frame(for: mode)
        let screenFrames = screens().map(\.visibleFrame)
        var frame = SystemMonitorWindowPlacement.frame(size: size, saved: saved, screens: screenFrames,
                                                       main: (NSScreen.main ?? screens().first)?.visibleFrame)
        if saved == nil, let anchor {
            frame.origin = CGPoint(x: anchor.x, y: anchor.y - size.height)
        }
        panel.setFrame(frame, display: true)
        // SwiftUI applies a new mode on its next pass; fit again once it has.
        DispatchQueue.main.async { [weak self] in self?.contentSizeChanged() }
    }

    private func saveFrame(_ panel: NSPanel) {
        let frame = panel.frame
        update { $0.setFrame(frame, for: $0.mode) }
    }

    private var isVisibleOnScreen: Bool { panel?.occlusionState.contains(.visible) ?? false }

    /// The content changed height (a metric hidden, processes arriving): keep the top edge still.
    func contentSizeChanged() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        guard abs(size.height - panel.frame.height) > 0.5 || abs(size.width - panel.frame.width) > 0.5 else { return }
        panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width,
                              height: size.height), display: true)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        saveFrame(panel)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let client, notification.object as? NSPanel === panel else { return }
        store.update(client, .init(processes: settings.mode == .full, visible: isVisibleOnScreen))
    }
}

/// A panel that can take keys for its menu without activating Typeflux; ⌘W closes it.
final class SystemMonitorPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_: Any?) {
        // Esc leaves the window where it is: it is meant to stay.
    }
}
