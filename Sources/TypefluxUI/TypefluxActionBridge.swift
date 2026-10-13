import AppKit
import SwiftUI

/// Keeps a SwiftUI action available to AppKit integrations without synthesizing a cell click.
struct TypefluxActionBridge: NSViewRepresentable {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    final class ActionView: NSView {
        var action: (() -> Void)?
        var enabled = true

        override func hitTest(_: NSPoint) -> NSView? { nil }

        @discardableResult func invoke() -> Bool {
            guard enabled, let action else { return false }
            action()
            return true
        }
    }

    func makeNSView(context _: Context) -> ActionView {
        let view = ActionView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ActionView, context _: Context) {
        view.action = action
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: ActionView, coordinator _: ()) { view.action = nil }
}

public extension View {
    /// Exposes the same action to AppKit callers while SwiftUI owns normal input and accessibility.
    func typefluxAction(_ action: @escaping () -> Void) -> some View {
        background(TypefluxActionBridge(action: action).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}
