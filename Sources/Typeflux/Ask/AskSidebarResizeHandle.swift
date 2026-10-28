import AppKit
import SwiftUI

/// A native divider owns its cursor and mouse tracking without moving the window.
struct AskSidebarResizeHandle: NSViewRepresentable {
    var width: CGFloat
    var resize: (CGFloat?) -> Void

    func makeNSView(context _: Context) -> AskSidebarResizeView {
        AskSidebarResizeView()
    }

    func updateNSView(_ view: AskSidebarResizeView, context _: Context) {
        view.resize = resize
        view.setAccessibilityLabel(L("ask.sidebar.resize"))
        view.setAccessibilityValue(width)
    }
}

final class AskSidebarResizeView: NSView {
    var resize: ((CGFloat?) -> Void)?
    private var startX: CGFloat?
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("ask.workspace.sidebar.resize")
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX else { return }
        resize?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with _: NSEvent) {
        guard startX != nil else { return }
        resize?(nil)
        startX = nil
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(by: 16)
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(by: -16)
    }

    private func adjust(by delta: CGFloat) -> Bool {
        guard let resize else { return false }
        resize(delta)
        resize(nil)
        return true
    }
}
