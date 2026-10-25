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

/// The middle of the ring: an app page shows that app's icon; two pages show page dots.
struct RingMenuCenter: Equatable {
    var appBundleIdentifier: String?
    var pageCount = 1
    var pageIndex = 0

    static let plain = RingMenuCenter()
}

private struct RingMenuPresentation: Equatable {
    var items: [RingMenuItem]
    var style: RingStyle
    var centerTitle: String
    var center: RingMenuCenter
}

/// The floating ring, behind a protocol so the controller is tested without a window.
@MainActor
protocol RingMenuPresenting: AnyObject {
    var isVisible: Bool { get }
    /// Called with the item id after the closing animation.
    var onSelect: (String) -> Void { get set }
    /// When set, a click in the middle (or Tab) calls this instead of closing the ring.
    var onCenterClick: (() -> Void)? { get set }
    /// Replaces what the ring shows. While it is open, the new items turn in place.
    func configure(items: [RingMenuItem], style: RingStyle, centerTitle: String, center: RingMenuCenter)
    func show(at point: CGPoint, takesKeyboardFocus: Bool)
    func focusKeyboard()
    func dismiss()
    /// Runs the slice under the pointer; false when the pointer is in the middle.
    func activatePointedItem() -> Bool
}

/// Opens the ring for the `.ring` shortcut and runs the chosen slice. When the app in front has
/// actions of its own, the ring opens with them; a click in the middle switches to the global ones.
@MainActor
final class RingController {
    /// Which actions the open ring shows.
    enum Page: Equatable {
        case global
        case app(UUID)
    }

    private let settingsStore: SettingsStore
    private let menu: any RingMenuPresenting
    private let executor: RingActionExecutor
    private let now: () -> TimeInterval
    private let pointerLocation: () -> CGPoint
    private let frontmostApplication: () -> NSRunningApplication?
    /// Voice input owns the keyboard while recording; the ring stays closed.
    var isRecordingActive: () -> Bool = { false }

    private(set) var configuration: RingConfiguration
    private(set) var page = Page.global
    /// The profile of the app that was in front when the ring opened, if it has one.
    private var openProfileID: UUID?
    /// What the menu was last given, so unrelated settings changes do not redraw an open ring.
    private var presented: RingMenuPresentation?
    private var gesture = RingHotkeyGesture()
    private var previousApplication: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []

    init(settingsStore: SettingsStore, menu: any RingMenuPresenting, executor: RingActionExecutor,
         pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.settingsStore = settingsStore
        self.menu = menu
        self.executor = executor
        self.pointerLocation = pointerLocation
        self.frontmostApplication = frontmostApplication
        configuration = settingsStore.ringConfiguration
        menu.onSelect = { [weak self] id in self?.select(id) }
        applyPage()
        for name in [Notification.Name.ringSettingsDidChange, .hotkeySettingsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: settingsStore,
                                                                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reload() }
                })
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        configuration = settingsStore.ringConfiguration
        if !menu.isVisible {
            openProfileID = nil
            page = .global
        } else if openProfile == nil {
            // The open app's profile was removed or emptied: fall back to the global actions.
            openProfileID = nil
            page = .global
        }
        applyPage()
        if !canOpen || (menu.isVisible && displayedActions.isEmpty) {
            gesture.reset()
            if menu.isVisible {
                menu.dismiss()
            }
        }
    }

    private var canOpen: Bool {
        settingsStore.actionHotkeys[.ring] != nil && configuration.isUsable
    }

    func pressBegan() {
        let location = pointerLocation()
        guard canOpen, !isRecordingActive() else { ShortcutLatency.record(.blocked); return }
        switch gesture.pressBegan(isVisible: menu.isVisible, at: now()) {
        case .show:
            let front = frontmostApplication()
            previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            openPage(for: previousApplication?.bundleIdentifier)
            guard !displayedActions.isEmpty else {
                gesture.reset()
                ShortcutLatency.record(.blocked)
                return
            }
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
        guard gesture.pressEnded(isVisible: menu.isVisible, at: now()) == .activate else {
            if menu.isVisible {
                menu.focusKeyboard()
            }
            return
        }
        // Let go in the middle: nothing is under the pointer, so the ring just closes.
        if !menu.activatePointedItem() {
            menu.dismiss()
        }
    }

    func cancelPress() {
        gesture.reset()
        if menu.isVisible {
            menu.dismiss()
        }
    }

    private func select(_ id: String) {
        guard let action = displayedActions.first(where: { $0.id.uuidString == id }) else { return }
        let previous = previousApplication
        Task { await executor.perform(action, previousApplication: previous) }
    }

    // MARK: - Pages

    private var openProfile: RingAppProfile? {
        guard let openProfileID else { return nil }
        return configuration.appProfiles.first { $0.id == openProfileID && $0.isActive }
    }

    /// The actions the ring shows now.
    var displayedActions: [RingAction] {
        if case .app = page, let profile = openProfile {
            return profile.actions
        }
        return configuration.actions
    }

    /// Switching needs both pages: an app profile and global actions to switch to.
    var canSwitchPage: Bool {
        openProfile != nil && !configuration.actions.isEmpty
    }

    /// Every opening starts with the front app's own actions when it has them. Typeflux itself in
    /// front has no previous application, so it always gets the global actions.
    private func openPage(for bundleIdentifier: String?) {
        let profile = configuration.profile(forBundleIdentifier: bundleIdentifier)
        openProfileID = profile?.id
        page = profile.map { .app($0.id) } ?? .global
        applyPage()
    }

    /// The middle of the ring was clicked, or Tab pressed: show the other page.
    func switchPage() {
        guard canSwitchPage, let profile = openProfile else { return }
        page = page == .global ? .app(profile.id) : .global
        applyPage()
    }

    private func applyPage() {
        let profile = openProfile
        let center: RingMenuCenter
        var title = configuration.centerTitle
        switch (page, profile) {
        case let (.app, profile?):
            title = profile.appName
            center = RingMenuCenter(appBundleIdentifier: profile.bundleIdentifier,
                                    pageCount: canSwitchPage ? 2 : 1, pageIndex: 0)
        default:
            center = canSwitchPage ? RingMenuCenter(pageCount: 2, pageIndex: 1) : .plain
        }
        menu.onCenterClick = canSwitchPage ? { [weak self] in self?.switchPage() } : nil
        let next = RingMenuPresentation(items: Self.items(for: displayedActions), style: configuration.style,
                                        centerTitle: title, center: center)
        guard next != presented else { return }
        presented = next
        menu.configure(items: next.items, style: next.style, centerTitle: next.centerTitle, center: next.center)
    }

    static func items(for actions: [RingAction]) -> [RingMenuItem] {
        actions.map { action in
            var bundleIdentifier: String?
            if case let .app(identifier, _) = action.kind {
                bundleIdentifier = identifier
            }
            return RingMenuItem(id: action.id.uuidString, label: RingSettingsPresentation.sliceLabel(action.title),
                                symbol: action.symbol, bundleIdentifier: bundleIdentifier)
        }
    }
}

/// `RingMenuPresenting` on top of the vendored OpieMenu package.
@MainActor
final class OpieRingMenu: RingMenuPresenting {
    var onSelect: (String) -> Void = { _ in }
    var onCenterClick: (() -> Void)? {
        get { menu.onCenterClick }
        set { menu.onCenterClick = newValue }
    }

    private lazy var menu = OpieRadialMenu(items: [], centerTitle: RingConfiguration.defaultCenterTitle,
                                           style: .frosted) { [weak self] item in self?.onSelect(item.id) }

    var isVisible: Bool {
        menu.isVisible
    }

    var hasKeyboardFocus: Bool {
        menu.hasKeyboardFocus
    }

    init(soundEffectPlayer: SoundEffectPlayer? = nil) {
        menu.onHover = { _ in
            _ = soundEffectPlayer?.play(.ringHover)
        }
    }

    func configure(items: [RingMenuItem], style: RingStyle, centerTitle: String, center: RingMenuCenter) {
        menu.setStyle(Self.style(style))
        let icon = center.appBundleIdentifier.flatMap(Self.appIcon(bundleIdentifier:))
        menu.showPage(items: items.map(Self.menuItem),
                      centerTitle: centerTitle.isEmpty ? RingConfiguration.defaultCenterTitle : centerTitle,
                      center: OpieMenuCenter(icon: icon, pageCount: center.pageCount, pageIndex: center.pageIndex))
        if !items.isEmpty, !menu.isVisible {
            menu.prepare()
        }
    }

    static func appIcon(bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
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
