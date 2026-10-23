import AppKit
import Foundation
import OpieMenu

/// One slice as the menu shows it.
struct RingMenuItem: Equatable {
    var id: String
    var label: String
    var symbol: String
    /// Apps show their own icon.
    var bundleIdentifier: String?
}

/// The floating ring, behind a protocol so the controller is tested without a window.
@MainActor
protocol RingMenuPresenting: AnyObject {
    var isVisible: Bool { get }
    /// Called with the item id after the closing animation.
    var onSelect: (String) -> Void { get set }
    func configure(items: [RingMenuItem], style: RingStyle, centerTitle: String)
    func show(at point: CGPoint, takesKeyboardFocus: Bool)
    func focusKeyboard()
    func dismiss()
    /// Runs the slice under the pointer; false when the pointer is in the middle.
    func activatePointedItem() -> Bool
}

/// Opens the ring for the `.ring` shortcut and runs the chosen slice.
@MainActor
final class RingController {
    private let settingsStore: SettingsStore
    private let menu: any RingMenuPresenting
    private let executor: RingActionExecutor
    private let pointerLocation: () -> CGPoint
    private let frontmostApplication: () -> NSRunningApplication?
    /// Voice input owns the keyboard while recording; the ring stays closed.
    var isRecordingActive: () -> Bool = { false }

    private(set) var configuration: RingConfiguration
    private var gesture = RingHotkeyGesture()
    private var previousApplication: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []

    init(settingsStore: SettingsStore, menu: any RingMenuPresenting, executor: RingActionExecutor,
         pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.settingsStore = settingsStore
        self.menu = menu
        self.executor = executor
        self.pointerLocation = pointerLocation
        self.frontmostApplication = frontmostApplication
        configuration = settingsStore.ringConfiguration
        menu.onSelect = { [weak self] id in self?.select(id) }
        apply(configuration)
        for name in [Notification.Name.ringSettingsDidChange, .hotkeySettingsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: settingsStore,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        configuration = settingsStore.ringConfiguration
        apply(configuration)
        if !canOpen {
            gesture.reset()
            if menu.isVisible { menu.dismiss() }
        }
    }

    private var canOpen: Bool {
        settingsStore.actionHotkeys[.ring] != nil && configuration.isUsable
    }

    func pressBegan() {
        let location = pointerLocation()
        guard canOpen, !isRecordingActive() else { ShortcutLatency.record(.blocked); return }
        switch gesture.pressBegan(isVisible: menu.isVisible, at: location) {
        case .show:
            let front = frontmostApplication()
            previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            let takesFocus = settingsStore.actionHotkeys[.ring]?.isSingleModifierTrigger != true
            ShortcutLatency.measure(.ringShowStarted, .ringShowFinished) {
                menu.show(at: location, takesKeyboardFocus: takesFocus)
            }
            ShortcutLatency.presentationOrdered { [weak menu] in menu?.isVisible == true }
        case .dismiss:
            ShortcutLatency.record(.dismissed)
            menu.dismiss()
        case .ignore:
            ShortcutLatency.record(.superseded)
        }
    }

    func pressEnded() {
        guard gesture.isHeld else { return }
        guard gesture.pressEnded(isVisible: menu.isVisible, at: pointerLocation()) == .activate else {
            if menu.isVisible { menu.focusKeyboard() }
            return
        }
        // Let go in the middle: nothing is under the pointer, so the ring just closes.
        if !menu.activatePointedItem() { menu.dismiss() }
    }

    func cancelPress() {
        gesture.reset()
        if menu.isVisible { menu.dismiss() }
    }

    private func select(_ id: String) {
        guard let index = configuration.actions.firstIndex(where: { $0.id.uuidString == id }) else { return }
        let action = configuration.actions[index]
        let previous = previousApplication
        Task { await executor.perform(action, previousApplication: previous) }
    }

    private func apply(_ configuration: RingConfiguration) {
        menu.configure(items: Self.items(for: configuration.actions), style: configuration.style,
                       centerTitle: configuration.centerTitle)
    }

    static func items(for actions: [RingAction]) -> [RingMenuItem] {
        actions.map { action in
            var bundleIdentifier: String?
            if case let .app(identifier, _) = action.kind { bundleIdentifier = identifier }
            return RingMenuItem(id: action.id.uuidString, label: RingSettingsPresentation.sliceLabel(action.title),
                                symbol: action.symbol, bundleIdentifier: bundleIdentifier)
        }
    }
}

/// `RingMenuPresenting` on top of the vendored OpieMenu package.
@MainActor
final class OpieRingMenu: RingMenuPresenting {
    var onSelect: (String) -> Void = { _ in }
    private lazy var menu = OpieRadialMenu(items: [], centerTitle: RingConfiguration.defaultCenterTitle,
                                          style: .frosted) { [weak self] item in self?.onSelect(item.id) }

    var isVisible: Bool {
        menu.isVisible
    }

    var hasKeyboardFocus: Bool { menu.hasKeyboardFocus }

    func configure(items: [RingMenuItem], style: RingStyle, centerTitle: String) {
        menu.updateItems(items.map(Self.menuItem))
        menu.setStyle(Self.style(style))
        menu.setCenterTitle(centerTitle.isEmpty ? RingConfiguration.defaultCenterTitle : centerTitle)
        if !items.isEmpty { menu.prepare() }
    }

    func show(at point: CGPoint, takesKeyboardFocus: Bool = true) {
        menu.show(at: point, takesKeyboardFocus: takesKeyboardFocus)
    }

    func focusKeyboard() {
        menu.focusKeyboard()
    }

    func dismiss() {
        menu.dismiss()
    }

    func activatePointedItem() -> Bool {
        menu.activatePointedItem()
    }

    static func style(_ style: RingStyle) -> OpieMenuStyle {
        switch style {
        case .classic: .classic
        case .frosted: .frosted
        case .liquidGlass: .liquidGlass
        }
    }

    private static func menuItem(_ item: RingMenuItem) -> OpieMenuItem {
        if let bundleIdentifier = item.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return OpieMenuItem(id: item.id, title: item.label, icon: .image(icon))
        }
        return OpieMenuItem(id: item.id, title: item.label, icon: .systemSymbol(item.symbol))
    }
}
