import AppKit
import SwiftUI

/// The home's keys, read before the editor sees them: ↑/↓, ←/→ and ⌘1…⌘9.
/// The handler returns false to let a key through to the editor.
struct AskLauncherHomeKeyMonitor: NSViewRepresentable {
    enum Key: Equatable {
        case vertical(Int)
        case horizontal(Int)
        case number(Int)
    }

    var onKey: (Key) -> Bool

    static let leftKeyCode: UInt16 = 123
    static let rightKeyCode: UInt16 = 124

    /// The key an event stands for, or nil for every other key.
    static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Key? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if let digit = AskLauncherNumberShortcuts.number(keyCode: keyCode, modifiers: modifiers,
                                                         characters: characters) {
            return .number(digit)
        }
        guard modifiers.isEmpty else { return nil }
        if let delta = AskArrowKeyMonitor.delta(keyCode: keyCode, modifiers: []) { return .vertical(delta) }
        switch keyCode {
        case leftKeyCode: return .horizontal(-1)
        case rightKeyCode: return .horizontal(1)
        default: return nil
        }
    }

    final class MonitorView: NSView {
        var onKey: (Key) -> Bool = { _ in false }
        private var monitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var trackingMenus = Set<ObjectIdentifier>()
        var capturesHomeKeys: Bool { trackingMenus.isEmpty }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            observeMenus()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.capturesHomeKeys, event.window === self.window,
                      (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      let key = AskLauncherHomeKeyMonitor.key(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                              characters: event.charactersIgnoringModifiers)
                else { return event }
                if event.isARepeat, case .number = key { return nil }
                return self.onKey(key) ? nil : event
            }
        }

        private func observeMenus() {
            menuObservers = [
                NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                       object: nil, queue: .main) { [weak self] notification in
                    guard let menu = notification.object as? NSMenu else { return }
                    self?.trackingMenus.insert(ObjectIdentifier(menu))
                },
                NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                       object: nil, queue: .main) { [weak self] notification in
                    guard let menu = notification.object as? NSMenu else { return }
                    self?.trackingMenus.remove(ObjectIdentifier(menu))
                }
            ]
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            menuObservers.forEach(NotificationCenter.default.removeObserver)
            menuObservers = []
            trackingMenus.removeAll()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            menuObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.onKey = onKey
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.removeFromSuperview()
    }
}
