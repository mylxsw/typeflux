import AppKit
import SwiftUI

/// Hover cards for the composer's context chips, drawn in a borderless panel
/// that never becomes key and ignores the mouse.
///
/// They used to be SwiftUI popovers, which made the chips hard to click. An
/// NSPopover is a transient window: once it was showing (150ms into a hover, so
/// nearly always by the time the user clicked) the mouse-down on the chip went
/// to closing the popover rather than to the button. The popover's window also
/// took key status from the launcher panel, so the next click only re-activated
/// the panel. A click registered only when it beat the hover delay, which is why
/// the chips felt randomly unresponsive.
@MainActor
final class AskHoverCardPresenter {
    static let shared = AskHoverCardPresenter()
    static let gap: CGFloat = 6
    static let screenMargin: CGFloat = 4

    private var panel: NSPanel?
    private var owner: UUID?

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static func makePanel() -> NSPanel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Purely informational: clicks pass through to whatever is underneath.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// Above the anchor and centred on it, kept on screen; below it when there
    /// is no room above.
    static func frame(size: NSSize, anchor: NSRect, screen: NSRect?) -> NSRect {
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + gap
        if let screen {
            x = min(max(x, screen.minX + screenMargin), screen.maxX - size.width - screenMargin)
            if y + size.height > screen.maxY { y = anchor.minY - gap - size.height }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func show(_ content: some View, owner: UUID, anchor: NSView) {
        guard let window = anchor.window, window.isVisible else { return }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: AnyView(AskGlassCardSurface { content }.askPopIn(anchor: .bottom)))
        panel.contentView = hosting
        panel.appearance = window.effectiveAppearance
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(Self.frame(size: hosting.fittingSize, anchor: anchorRect, screen: window.screen?.visibleFrame),
                       display: true)
        // A child window is ordered out with its parent, so a card can never
        // outlive the launcher it belongs to.
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        self.owner = owner
    }

    /// Hides the card only if `owner` still owns it, so a chip leaving never
    /// hides the card its neighbour has just shown.
    func hide(owner: UUID) {
        guard self.owner == owner, let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.owner = nil
    }
}

/// Locates a SwiftUI view in its window for `AskHoverCardPresenter`. Invisible
/// to the mouse, so it never takes a click from the view it sits behind.
struct AskHoverAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = Passthrough()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }

    private final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
