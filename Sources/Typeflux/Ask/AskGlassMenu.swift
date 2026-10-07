import AppKit
import SwiftUI

/// The composer's menus (model, reasoning) as arrowless glass cards above
/// their button, matching the launcher. An `NSPopover` drew a system arrow and
/// its own opaque chrome, which the design does not have.
///
/// The card lives in a borderless child panel that never becomes key, so the
/// launcher keeps keyboard focus. It closes on a click outside it, on Esc, and
/// when the launcher hides.
@MainActor
final class AskGlassMenuPresenter {
    static let shared = AskGlassMenuPresenter()
    nonisolated static let gap: CGFloat = 8
    static let screenMargin: CGFloat = 8
    /// Lines the menu's rows up with the button's text.
    static let leadingOffset: CGFloat = 6

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click even though the panel is never key, and resizes
    /// the panel when its content changes size (e.g. the model catalog loads).
    final class HostingView<Content: View>: NSHostingView<Content> {
        var onResize: (() -> Void)?
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onResize?() }
        }
    }

    private(set) var panel: NSPanel?
    private(set) var owner: UUID?
    private weak var anchor: NSView?
    private var onClose: (() -> Void)?
    private var monitors: [Any] = []

    var isShowing: Bool { owner != nil }

    /// Above the anchor, leading edges aligned; below it when there is no room
    /// above; always kept on screen.
    static func frame(size: NSSize, anchor: NSRect, screen: NSRect?) -> NSRect {
        var x = anchor.minX - leadingOffset
        var y = anchor.maxY + gap
        if let screen {
            x = min(max(x, screen.minX + screenMargin), screen.maxX - size.width - screenMargin)
            if y + size.height > screen.maxY - screenMargin { y = anchor.minY - gap - size.height }
            y = max(y, screen.minY + screenMargin)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func makePanel() -> NSPanel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    func show(_ content: some View, owner: UUID, anchor: NSView, onClose: @escaping () -> Void) {
        guard let window = anchor.window, window.isVisible else { onClose(); return }
        if self.owner != nil, self.owner != owner { hide() }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let hosting = HostingView(rootView: AnyView(
            // Menus open above their button, so they grow out of its corner.
            AskGlassCardSurface(corner: AskGlassCardSurface<EmptyView>.menuCorner) { content }
                .askPopIn(anchor: .bottomLeading)
        ))
        hosting.onResize = { [weak self] in self?.place() }
        panel.contentView = hosting
        panel.appearance = window.effectiveAppearance
        self.anchor = anchor
        self.owner = owner
        self.onClose = onClose
        place()
        // A child window is ordered out with its parent and stays above it.
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        installMonitors()
    }

    /// Closes the menu if `owner` (or anyone, when nil) still owns it.
    func hide(owner: UUID? = nil) {
        guard self.owner != nil, owner == nil || owner == self.owner else { return }
        removeMonitors()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        let close = onClose
        self.owner = nil
        self.onClose = nil
        anchor = nil
        close?()
    }

    private func place() {
        guard let panel, let anchor, let window = anchor.window, let content = panel.contentView else { return }
        let size = content.fittingSize
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(Self.frame(size: size, anchor: anchorRect, screen: window.screen?.visibleFrame), display: true)
    }

    /// Whether a click should close the menu: anywhere except the menu itself
    /// and its own button (the button toggles it closed on its own).
    func shouldClose(forClickIn window: NSWindow?, at screenPoint: NSPoint) -> Bool {
        guard let panel, isShowing else { return false }
        if window === panel { return false }
        if let anchor, let anchorWindow = anchor.window {
            let rect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if rect.contains(screenPoint) { return false }
        }
        return true
    }

    /// Whether a screen point is over the open card or its anchor, give or
    /// take `slop` so the gap between them does not count as leaving.
    func containsPointer(_ point: NSPoint, slop: CGFloat = gap) -> Bool {
        guard isShowing else { return false }
        if let panel, panel.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return true }
        if let anchor, let window = anchor.window {
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            return rect.insetBy(dx: -slop, dy: -slop).contains(point)
        }
        return false
    }

    private func installMonitors() {
        removeMonitors()
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event } // Esc closes the menu, not the launcher.
                self.hide()
                return nil
            }
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            if self.shouldClose(forClickIn: event.window, at: point) { self.hide() }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.hide()
        }) { monitors.append(global) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Presents `menu` with `AskGlassMenuPresenter` while `isPresented` is true.
struct AskGlassMenu<Menu: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var menu: () -> Menu
    @State private var anchor = AskHoverAnchor.Holder()
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .background(AskHoverAnchor(holder: anchor))
            .onChange(of: isPresented) { show in
                if show {
                    guard let view = anchor.view else { isPresented = false; return }
                    AskGlassMenuPresenter.shared.show(menu(), owner: id, anchor: view) { isPresented = false }
                } else {
                    AskGlassMenuPresenter.shared.hide(owner: id)
                }
            }
            .onDisappear { AskGlassMenuPresenter.shared.hide(owner: id) }
    }
}

extension View {
    /// The composer's glass menu, or the system popover elsewhere (settings).
    @ViewBuilder
    func askMenu<Menu: View>(isPresented: Binding<Bool>, glass: Bool,
                             @ViewBuilder menu: @escaping () -> Menu) -> some View {
        if glass {
            modifier(AskGlassMenu(isPresented: isPresented, menu: menu))
        } else {
            popover(isPresented: isPresented, arrowEdge: .bottom, content: menu)
        }
    }
}
