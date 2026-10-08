import AppKit
import SwiftUI

/// The same 1...9 numbering is used by launcher and clipboard lists.
enum AskLauncherNumberShortcuts {
    static func number(at index: Int) -> Int? {
        (0..<9).contains(index) ? index + 1 : nil
    }

    static func number(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]) == .command else { return nil }
        if let characters, !characters.isEmpty {
            guard characters.count == 1, let digit = Int(characters), (1...9).contains(digit) else { return nil }
            return digit
        }
        // Hardware fallback for events without characters, including synthetic events.
        return [UInt16(18): 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9][keyCode]
    }
}

private struct AskLauncherNumberHintsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var askLauncherNumberHints: Bool {
        get { self[AskLauncherNumberHintsKey.self] }
        set { self[AskLauncherNumberHintsKey.self] = newValue }
    }
}

/// An overlay near the icon; showing hints never changes the row's layout.
struct AskLauncherNumberBadge: ViewModifier {
    @Environment(\.askLauncherNumberHints) private var visible
    var number: Int?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if visible, let number, (1...9).contains(number) {
                Text(String(number))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 17, height: 17)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .padding(.leading, 29)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Observe modifiers only in the hosting window and clear hints when it loses focus.
struct AskLauncherCommandMonitor: NSViewRepresentable {
    var onChange: (Bool) -> Void

    final class MonitorView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private(set) var showing = false

        func update(modifiers: NSEvent.ModifierFlags, isKeyWindow: Bool) {
            let next = isKeyWindow && modifiers.intersection([.command, .option, .control, .shift]) == .command
            guard next != showing else { return }
            showing = next
            onChange(next)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.update(modifiers: event.modifierFlags, isKeyWindow: self.window?.isKeyWindow == true)
                return event
            }
            observers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                       queue: .main) { [weak self] _ in
                    self?.update(modifiers: NSEvent.modifierFlags, isKeyWindow: true)
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                       queue: .main) { [weak self] _ in
                    self?.update(modifiers: [], isKeyWindow: false)
                }
            ]
            // Defer the initial publish until SwiftUI finishes attaching the view.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.update(modifiers: NSEvent.modifierFlags, isKeyWindow: self.window?.isKeyWindow == true)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            update(modifiers: [], isKeyWindow: false)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) { view.onChange = onChange }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) { view.stop() }
}
