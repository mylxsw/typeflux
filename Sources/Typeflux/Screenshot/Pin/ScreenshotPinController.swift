import AppKit
import SwiftUI

/// What a pinned screenshot asks the coordinator for.
enum ScreenshotPinEvent {
    case copy(CGImage, scale: CGFloat)
    case save(CGImage, scale: CGFloat)
    /// Mark it up again in the editor; `screen` is the display it was on, in global Quartz points.
    case edit(CGImage, scale: CGFloat, screen: CGRect)
}

/// Screenshots pinned above other windows, to look at while working.
@MainActor
protocol ScreenshotPinPresenting: AnyObject {
    /// - Parameter rect: where the region was, in global Quartz points; the pin opens there.
    func pin(_ image: CGImage, scale: CGFloat, at rect: CGRect, onEvent: @escaping (ScreenshotPinEvent) -> Void)
    var pinCount: Int { get }
    /// Pins that let clicks through; their recovery controls and the menu bar stay available.
    var clickThroughCount: Int { get }
    /// Every pin takes the mouse again.
    func restoreMouse()
    func closeAll()
}

/// A borderless panel that floats above normal windows on every Space and can be moved by its picture.
final class ScreenshotPinPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow
    }

    // Keys such as esc and ⌘C reach the pin once it is clicked, without activating Typeflux.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ScreenshotPinController: ScreenshotPinPresenting {
    private(set) var panels: [ScreenshotPinPanel] = []
    private var recoveryPanels: [ObjectIdentifier: ScreenshotPinPanel] = [:]
    private let primaryDisplayHeight: () -> CGFloat

    init(primaryDisplayHeight: @escaping () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 }) {
        self.primaryDisplayHeight = primaryDisplayHeight
    }

    var pinCount: Int { panels.count }

    var clickThroughCount: Int {
        views.filter(\.state.clickThrough).count
    }

    var views: [ScreenshotPinView] { panels.compactMap { $0.contentView as? ScreenshotPinView } }

    func pin(_ image: CGImage, scale: CGFloat, at rect: CGRect, onEvent: @escaping (ScreenshotPinEvent) -> Void) {
        let frame = ScreenCaptureGeometry.flipped(rect, primaryDisplayHeight: primaryDisplayHeight())
        let panel = ScreenshotPinPanel(frame: frame)
        let view = ScreenshotPinView(image: image, scale: scale, frame: CGRect(origin: .zero, size: frame.size))
        view.onAction = { [weak self, weak panel] action in
            guard let self, let panel else { return }
            self.perform(action, on: panel, image: image, scale: scale, onEvent: onEvent)
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    func restoreMouse() {
        for view in views where view.state.clickThrough {
            view.state.clickThrough = false
        }
    }

    func closeAll() {
        for panel in panels { close(panel) }
    }

    private func perform(_ action: ScreenshotPinView.Action, on panel: ScreenshotPinPanel, image: CGImage,
                         scale: CGFloat, onEvent: (ScreenshotPinEvent) -> Void) {
        switch action {
        case .close:
            close(panel)
        case .copy:
            onEvent(.copy(image, scale: scale))
        case .save:
            onEvent(.save(image, scale: scale))
        case .edit:
            let screen = (panel.screen ?? NSScreen.main)?.frame ?? panel.frame
            close(panel)
            onEvent(.edit(image, scale: scale,
                          screen: ScreenCaptureGeometry.flipped(screen, primaryDisplayHeight: primaryDisplayHeight())))
        case let .changed(state):
            guard let view = panel.contentView as? ScreenshotPinView else { return }
            panel.setFrame(state.frame(keepingTopLeftOf: panel.frame, imageSize: view.imageSize), display: true)
            panel.alphaValue = state.opacity
            panel.ignoresMouseEvents = state.clickThrough
            updateRecoveryControls(for: panel, clickThrough: state.clickThrough)
        }
    }

    /// A separate child window still receives clicks when the image lets them through.
    func recoveryPanel(for panel: ScreenshotPinPanel) -> ScreenshotPinPanel? {
        recoveryPanels[ObjectIdentifier(panel)]
    }

    private func updateRecoveryControls(for panel: ScreenshotPinPanel, clickThrough: Bool) {
        guard clickThrough else {
            removeRecoveryControls(for: panel)
            return
        }
        let recovery: ScreenshotPinPanel
        if let existing = recoveryPanel(for: panel) {
            recovery = existing
        } else {
            recovery = ScreenshotPinPanel(frame: .zero)
            recovery.isMovableByWindowBackground = false
            let controls = ScreenshotPinRecoveryView()
            controls.onRestore = { [weak panel] in
                (panel?.contentView as? ScreenshotPinView)?.state.clickThrough = false
            }
            controls.onClose = { [weak self, weak panel] in
                guard let panel else { return }
                self?.close(panel)
            }
            recovery.contentView = controls
            recovery.makeFirstResponder(controls)
            recoveryPanels[ObjectIdentifier(panel)] = recovery
            panel.addChildWindow(recovery, ordered: .above)
        }
        let size = ScreenshotPinRecoveryView.size
        recovery.setFrame(CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.minY + 8,
                                 width: size.width, height: size.height), display: true)
        recovery.orderFrontRegardless()
    }

    private func removeRecoveryControls(for panel: ScreenshotPinPanel) {
        guard let recovery = recoveryPanels.removeValue(forKey: ObjectIdentifier(panel)) else { return }
        panel.removeChildWindow(recovery)
        recovery.orderOut(nil)
        recovery.contentView = nil
    }

    private func close(_ panel: ScreenshotPinPanel) {
        removeRecoveryControls(for: panel)
        panel.orderOut(nil)
        (panel.contentView as? ScreenshotPinView)?.releaseImage()
        panel.contentView = nil
        panels.removeAll { $0 === panel }
    }
}

/// The pinned picture. Drag to move it, scroll to zoom (⌥ for opacity), double-click or esc to close;
/// the bar on hover and the right-click menu have the rest.
@MainActor
final class ScreenshotPinView: NSView {
    enum Action: Equatable {
        case close, copy, save, edit
        case changed(ScreenshotPinState)
    }

    /// The image's size in points at 100 %.
    let imageSize: CGSize
    var onAction: ((Action) -> Void)?
    var state = ScreenshotPinState() {
        didSet {
            guard state != oldValue else { return }
            onAction?(.changed(state))
            refreshBar()
        }
    }

    private let imageLayer = CALayer()
    private(set) var bar: NSHostingView<AnyView>?
    private(set) var isHovered = false

    /// The bar only shows on pins wide enough to hold it.
    static let barMinimumWidth: CGFloat = 250

    init(image: CGImage, scale: CGFloat, frame: CGRect) {
        let scale = max(scale, 1)
        imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func releaseImage() {
        imageLayer.contents = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBar()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBar()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            onAction?(.close)
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        state.scroll(by: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                     adjustsOpacity: event.modifierFlags.contains(.option))
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event.keyCode, modifiers: event.modifierFlags) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        return handleKey(event.keyCode, modifiers: event.modifierFlags)
    }

    /// Esc and delete close the pin, ⌘C copies, ⌘S saves, ⌘0 goes back to 100 %.
    @discardableResult
    func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        typealias Key = ScreenshotOverlayView.Key
        let command = modifiers.contains(.command)
        switch keyCode {
        case Key.escape, Key.delete, Key.forwardDelete: onAction?(.close)
        case Key.keyC where command: onAction?(.copy)
        case Key.keyS where command: onAction?(.save)
        case Self.zeroKeyCode where command: state.zoom = 1
        default: return false
        }
        return true
    }

    static let zeroKeyCode: UInt16 = 29

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    /// Copy, save, mark up again, click-through and close.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        item(L("screenshot.edit.copy"), #selector(copyFromMenu), key: "c")
        item(L("screenshot.edit.save"), #selector(saveFromMenu), key: "s")
        item(L("screenshot.pin.edit"), #selector(editFromMenu))
        menu.addItem(.separator())
        item(L("screenshot.pin.actualSize"), #selector(actualSizeFromMenu), key: "0")
        item(L("screenshot.pin.clickThrough"), #selector(clickThroughFromMenu))
        menu.addItem(.separator())
        item(L("screenshot.pin.close"), #selector(closeFromMenu))
        return menu
    }

    @objc private func copyFromMenu() { onAction?(.copy) }
    @objc private func saveFromMenu() { onAction?(.save) }
    @objc private func editFromMenu() { onAction?(.edit) }
    @objc private func actualSizeFromMenu() { state.zoom = 1 }
    @objc private func clickThroughFromMenu() { state.clickThrough = true }
    @objc private func closeFromMenu() { onAction?(.close) }

    /// The bar's buttons.
    func perform(_ action: ScreenshotPinBar.Action) {
        switch action {
        case .zoomOut: state.zoom(by: -1)
        case .zoomIn: state.zoom(by: 1)
        case .opacity: state.opacity = state.opacity > 0.75 ? 0.5 : 1
        case .clickThrough: state.clickThrough = true
        case .edit: onAction?(.edit)
        case .copy: onAction?(.copy)
        case .save: onAction?(.save)
        case .close: onAction?(.close)
        }
    }

    private func refreshBar() {
        let shows = isHovered && !state.clickThrough && bounds.width >= Self.barMinimumWidth
        guard shows else {
            bar?.isHidden = true
            return
        }
        let content = AnyView(ScreenshotPinBar(state: state) { [weak self] in self?.perform($0) })
        let host: NSHostingView<AnyView>
        if let bar {
            host = bar
            host.rootView = content
        } else {
            host = NSHostingView(rootView: content)
            addSubview(host)
            bar = host
        }
        host.isHidden = false
        let size = host.fittingSize
        host.frame = CGRect(x: (bounds.width - size.width) / 2, y: 8, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        refreshBar()
    }
}

/// The controls along the bottom of a hovered pin.
struct ScreenshotPinBar: View {
    enum Action: CaseIterable {
        case zoomOut, zoomIn, opacity, clickThrough, edit, copy, save, close
    }

    let state: ScreenshotPinState
    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("minus", help: L("screenshot.pin.zoomOut")) { perform(.zoomOut) }
            Text(state.zoomLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38)
            button("plus", help: L("screenshot.pin.zoomIn")) { perform(.zoomIn) }
            divider
            button("circle.lefthalf.filled", help: L("screenshot.pin.opacity")) { perform(.opacity) }
            button("cursorarrow.motionlines", help: L("screenshot.pin.clickThrough")) { perform(.clickThrough) }
            divider
            button("square.and.pencil", help: L("screenshot.pin.edit")) { perform(.edit) }
            button("doc.on.doc", help: L("screenshot.edit.copy")) { perform(.copy) }
            button("square.and.arrow.down", help: L("screenshot.edit.save")) { perform(.save) }
            button("xmark", help: L("screenshot.pin.close")) { perform(.close) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(AskTheme.glassFill.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AskTheme.border, lineWidth: 1))
        .fixedSize()
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var divider: some View {
        Rectangle().fill(AskTheme.border).frame(width: 1, height: 14).padding(.horizontal, 3)
    }
}
