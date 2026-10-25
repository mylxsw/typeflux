import AppKit
import Carbon

/// Owns the floating radial menu. Keep one instance for the lifetime of the host app.
@MainActor
public final class OpieRadialMenu {
    public var onSelect: (OpieMenuItem) -> Void
    public var onWillShow: (() -> Void)?
    public var onDismiss: (() -> Void)?

    public private(set) var items: [OpieMenuItem]
    public private(set) var centerTitle: String
    public private(set) var style: OpieMenuStyle
    public private(set) var lastPresentationCenter: NSPoint?
    public var isVisible: Bool { panel?.isVisible == true }
    public var hasKeyboardFocus: Bool { panel?.isKeyWindow == true }
    var preparedWindow: NSWindow? { panel }

    private let size = NSSize(width: 620, height: 620)
    private var panel: MenuPanel?
    private var surface: RadialMenuSurface?
    private var view: RadialMenuView?
    private var reusableView: RadialMenuView?
    private var isDismissing = false
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private nonisolated let hotKeyIdentifier = UInt32.random(in: 1...UInt32.max)
    private var hotKeyHeld = false
    private var hotKeyOpenedMenu = false
    private var hotKeyPressLocation: NSPoint?

    public init(items: [OpieMenuItem], centerTitle: String = "Menu",
                style: OpieMenuStyle = .classic,
                onSelect: @escaping (OpieMenuItem) -> Void) {
        self.items = items
        self.centerTitle = centerTitle
        self.style = style.isAvailable ? style : .frosted
        self.onSelect = onSelect
    }

    isolated deinit {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Prepares graphics, material and a hidden reusable window without taking focus.
    public func prepare() {
        if reusableView == nil {
            reusableView = RadialMenuView(frame: NSRect(origin: .zero, size: size),
                                          items: items, centerTitle: centerTitle)
        }
        reusableView?.style = style
        reusableView?.prepareGraphics()
        preparePanel()
    }

    private func preparePanel() {
        guard panel == nil, let view = reusableView else { return }
        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        view.onSelect = { [weak self] item in self?.select(item) }
        view.onClose = { [weak self] in self?.dismiss() }
        let surface = RadialMenuSurface(frame: NSRect(origin: .zero, size: size), menu: view)
        panel.contentView = surface
        self.panel = panel
        self.view = view
        self.surface = surface
    }

    /// Replaces the actions, including their current titles. Three to eight items fit the layout best.
    public func updateItems(_ items: [OpieMenuItem]) {
        self.items = items
        reusableView?.update(items: items, centerTitle: centerTitle)
        if view !== reusableView { view?.update(items: items, centerTitle: centerTitle) }
        surface?.updateGlassShape()
        if items.isEmpty && isVisible { dismiss() }
    }

    public func setCenterTitle(_ title: String) {
        centerTitle = title
        reusableView?.update(items: items, centerTitle: title)
        if view !== reusableView { view?.update(items: items, centerTitle: title) }
    }

    public func setStyle(_ style: OpieMenuStyle) {
        self.style = style.isAvailable ? style : .frosted
        reusableView?.style = self.style
        view?.style = self.style
        surface?.updateGlassShape()
    }

    /// Opens at a global screen point. The panel stays inside the visible area of that screen.
    public func show(at screenPoint: NSPoint = NSEvent.mouseLocation, takesKeyboardFocus: Bool = true) {
        guard !isVisible, !items.isEmpty else { return }
        onWillShow?()
        guard !items.isEmpty else { return }
        prepare()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: min(max(screenPoint.x - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4),
            y: min(max(screenPoint.y - size.height / 2, visible.minY + 4), visible.maxY - size.height - 4)
        )
        lastPresentationCenter = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let panel, let view else { return }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        view.style = style
        view.prepareForOpening()
        surface?.updateGlassShape()
        panel.orderFrontRegardless()
        if takesKeyboardFocus { panel.makeKey() }
        isDismissing = false
        installEventMonitors()
        view.animateIn()
    }

    /// Enables keyboard navigation after a modifier-only tap, without stealing focus during a hold.
    public func focusKeyboard() {
        guard isVisible, !isDismissing else { return }
        panel?.makeKey()
    }

    public func toggle(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        if isVisible { dismiss() } else { show(at: screenPoint) }
    }

    /// Cancellation hides immediately; only committing an action plays the closing motion.
    public func dismiss(completion: (() -> Void)? = nil) {
        dismiss(animated: false, completion: completion)
    }

    private func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        guard let panel, panel.isVisible else { completion?(); return }
        guard !isDismissing else { return }
        isDismissing = true
        let finish: () -> Void = { [weak self, weak panel] in
            panel?.orderOut(nil)
            guard let self else { completion?(); return }
            if self.panel === panel {
                self.isDismissing = false
            }
            self.removeEventMonitors()
            self.onDismiss?()
            completion?()
        }
        if animated, let view {
            view.animateOut(completion: finish)
        } else {
            view?.stopMotion()
            finish()
        }
    }

    /// Activates the sector under the current pointer, useful when a host app handles key release itself.
    @discardableResult
    public func activatePointedItem() -> Bool {
        guard isVisible, !isDismissing else { return false }
        return view?.activatePointerSelection() ?? false
    }

    public func moveSelection(_ delta: Int) {
        guard isVisible, !isDismissing else { return }
        view?.moveSelection(delta)
    }
    public func select(index: Int) {
        guard isVisible, !isDismissing else { return }
        view?.select(index: index)
    }
    public func activateSelection() {
        guard isVisible, !isDismissing else { return }
        view?.activateSelection()
    }

    /// Registers an optional global shortcut using Carbon key codes and modifier flags.
    /// For example, Control–Option–Space is keyCode 49 and modifiers controlKey | optionKey.
    @discardableResult
    public func installGlobalHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        removeGlobalHotKey()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let menu = Unmanaged<OpieRadialMenu>.fromOpaque(userData).takeUnretainedValue()
            var incoming = EventHotKeyID()
            let parameterStatus = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                                    EventParamType(typeEventHotKeyID), nil,
                                                    MemoryLayout<EventHotKeyID>.size, nil, &incoming)
            guard parameterStatus == noErr, incoming.id == menu.hotKeyIdentifier,
                  incoming.signature == OSType(0x4F504945) else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            Task { @MainActor in
                if kind == UInt32(kEventHotKeyPressed) { menu.handleHotKeyPressed() }
                else if kind == UInt32(kEventHotKeyReleased) { menu.handleHotKeyReleased() }
            }
            return noErr
        }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased))
        ]
        let handlerStatus = eventTypes.withUnsafeMutableBufferPointer { events in
            InstallEventHandler(GetApplicationEventTarget(), callback, events.count,
                                events.baseAddress, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        guard handlerStatus == noErr else { return false }
        let identifier = EventHotKeyID(signature: OSType(0x4F504945), id: hotKeyIdentifier)
        let hotKeyStatus = RegisterEventHotKey(keyCode, modifiers, identifier,
                                               GetApplicationEventTarget(), 0, &hotKeyRef)
        if hotKeyStatus != noErr { removeGlobalHotKey() }
        return hotKeyStatus == noErr
    }

    public func removeGlobalHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        hotKeyHeld = false
        hotKeyOpenedMenu = false
        hotKeyPressLocation = nil
    }

    private func select(_ item: OpieMenuItem) {
        dismiss(animated: true) { [weak self] in self?.onSelect(item) }
    }

    private func handleHotKeyPressed() {
        guard !hotKeyHeld else { return }
        hotKeyHeld = true
        hotKeyOpenedMenu = !isVisible
        hotKeyPressLocation = NSEvent.mouseLocation
        toggle()
    }

    private func handleHotKeyReleased() {
        guard hotKeyHeld else { return }
        hotKeyHeld = false
        defer { hotKeyOpenedMenu = false; hotKeyPressLocation = nil }
        guard hotKeyOpenedMenu, isVisible, !isDismissing,
              let origin = hotKeyPressLocation,
              hypot(NSEvent.mouseLocation.x - origin.x, NSEvent.mouseLocation.y - origin.y) >= 20 else { return }
        _ = activatePointedItem()
    }

    private func installEventMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.dismiss()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            if !panel.frame.contains(screenPoint) { self.dismiss() }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, !self.isDismissing, self.panel?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 53: self.dismiss(); return nil
            case 123, 126: self.moveSelection(-1); return nil
            case 124, 125: self.moveSelection(1); return nil
            case 36, 76: self.activateSelection(); return nil
            case 18...25:
                let index = Int(event.keyCode - 18)
                if self.items.indices.contains(index) { self.select(index: index); self.activateSelection(); return nil }
                return event
            default: return event
            }
        }
    }

    private func removeEventMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
