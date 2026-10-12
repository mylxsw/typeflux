import AppKit
import SwiftUI

/// Only intercept events while a tile in this grid owns keyboard focus.
struct EmojiGridKeyboard: NSViewRepresentable {
    var focused: Bool
    var onKey: (Key) -> Void

    enum Key: Equatable {
        case move(Int), copy, insert, copyAndStay

        static func resolve(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Key? {
            let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            if flags == .command, code == 8 {
                return .copyAndStay
            }
            if code == 36 || code == 76 {
                if flags.isEmpty {
                    return .copy
                }
                if flags == .option {
                    return .insert
                }
            }
            guard flags.isEmpty else { return nil }
            switch code {
            case 123: return .move(-1)
            case 124: return .move(1)
            case 126: return .move(-EmojiResultsView.columns)
            case 125: return .move(EmojiResultsView.columns)
            default: return nil
            }
        }
    }

    final class Coordinator {
        var parent: EmojiGridKeyboard
        weak var view: NSView?
        var monitor: Any?
        init(_ parent: EmojiGridKeyboard) {
            self.parent = parent
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard parent.focused, event.window === view?.window, event.window != nil,
                  (event.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                  let key = Key.resolve(code: event.keyCode, modifiers: event.modifierFlags) else { return event }
            parent.onKey(key)
            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
