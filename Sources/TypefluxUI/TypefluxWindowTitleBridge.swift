import AppKit
import SwiftUI

/// Keep window metadata while the visible title leads the detail toolbar.
/// SwiftUI restores title visibility and centers principal items during toolbar updates.
struct TypefluxWindowTitleBridge: NSViewRepresentable {
    static let itemIdentifier = "typeflux.window.title"
    let title: String
    var actionTitles: Set<String> = []
    var actionIdentifiers: Set<String> = []
    var trailingItemIdentifiers: Set<String> = []

    final class TitleView: NSView {
        var representedWindowTitle = ""
        var actionTitles: Set<String> = []
        var actionIdentifiers: Set<String> = []
        var trailingItemIdentifiers: Set<String> = []
        private var active = false
        private var titleObservation: NSKeyValueObservation?
        private var visibilityObservation: NSKeyValueObservation?
        private var toolbarObservation: NSKeyValueObservation?
        private var centerObservation: NSKeyValueObservation?
        private var itemOrderObservation: NSKeyValueObservation?
        private var itemNotifications: [NSObjectProtocol] = []
        private var isSynchronizingTitle = false
        private weak var observedToolbar: NSToolbar?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            active = true
            titleObservation = window.observe(\.title) { [weak self] _, _ in self?.schedule() }
            visibilityObservation = window.observe(\.titleVisibility) { [weak self] _, _ in self?.schedule() }
            toolbarObservation = window.observe(\.toolbar) { [weak self] _, _ in self?.schedule() }
            synchronize()
            schedule()
        }

        func schedule() {
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }

        func synchronize() {
            guard active, !isSynchronizingTitle, let window else { return }
            isSynchronizingTitle = true
            defer { isSynchronizingTitle = false }
            if window.title != representedWindowTitle { window.title = representedWindowTitle }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if observedToolbar !== window.toolbar {
                centerObservation = nil
                itemOrderObservation = nil
                itemNotifications.forEach(NotificationCenter.default.removeObserver)
                itemNotifications.removeAll()
                observedToolbar = window.toolbar
                centerObservation = window.toolbar?.observe(\.centeredItemIdentifiers) { [weak self] _, _ in
                    self?.schedule()
                }
                #if compiler(>=6.0)
                    if #available(macOS 15, *) {
                        itemOrderObservation = window.toolbar?.observe(\.itemIdentifiers) { [weak self] _, _ in
                            self?.schedule()
                        }
                    }
                #endif
                if let toolbar = window.toolbar {
                    for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
                        itemNotifications.append(NotificationCenter.default.addObserver(
                            forName: name, object: toolbar, queue: .main
                        ) { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } })
                    }
                }
            }
            if let toolbar = window.toolbar {
                TypefluxToolbarAlignment.alignTrailingItems(in: toolbar, identifiers: trailingItemIdentifiers)
                if let item = toolbar.items.first(where: {
                    $0.itemIdentifier.rawValue == TypefluxWindowTitleBridge.itemIdentifier
                        || $0.view?.accessibilityIdentifier() == TypefluxWindowTitleBridge.itemIdentifier
                        || $0.label == representedWindowTitle
                }) {
                    if toolbar.centeredItemIdentifiers.contains(item.itemIdentifier) {
                        toolbar.centeredItemIdentifiers.remove(item.itemIdentifier)
                    }
                    if trailingItemIdentifiers.isEmpty { alignTitle(item, in: toolbar) }
                }
                // Keep this window's fixed tabs and primary actions accessible before native overflow.
                // A toolbar group may represent its action in the group label rather than subitems.
                for item in toolbar.items {
                    if item.itemIdentifier.rawValue == "typeflux.window.segments", item.visibilityPriority != .user {
                        item.visibilityPriority = .user
                    }
                    let titles = [item.label] + ((item as? NSToolbarItemGroup)?.subitems.map(\.label) ?? [])
                    let identifiers = [item.itemIdentifier.rawValue]
                        + ((item as? NSToolbarItemGroup)?.subitems.map { $0.itemIdentifier.rawValue } ?? [])
                    let isPrimary = titles.contains(where: actionTitles.contains)
                        || identifiers.contains(where: actionIdentifiers.contains)
                    if isPrimary,
                       item.visibilityPriority.rawValue < NSToolbarItem.VisibilityPriority.high.rawValue {
                        item.visibilityPriority = .high
                    }
                }
            }
        }

        private func alignTitle(_ item: NSToolbarItem, in toolbar: NSToolbar) {
            let separator = toolbar.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.first {
                isDescendant(of: $0.splitView)
            }
            let sidebarVisible = separator.map { separator in
                let panes = separator.splitView.subviews
                guard panes.indices.contains(separator.dividerIndex) else { return false }
                let sidebar = panes[separator.dividerIndex]
                return !separator.splitView.isSubviewCollapsed(sidebar) && sidebar.frame.width > 0
            } ?? false
            let current = toolbar.items.map(\.itemIdentifier)
            let desired = TypefluxWindowTitleBridge.titleOrder(
                current, title: item.itemIdentifier, separator: sidebarVisible ? separator?.itemIdentifier : nil
            )
            guard desired != current else { return }
            #if compiler(>=6.0)
                if #available(macOS 15, *) {
                    toolbar.itemIdentifiers = desired
                    return
                }
            #endif
            if let oldIndex = current.firstIndex(of: item.itemIdentifier),
               let newIndex = desired.firstIndex(of: item.itemIdentifier) {
                toolbar.removeItem(at: oldIndex)
                toolbar.insertItem(withItemIdentifier: item.itemIdentifier, at: newIndex)
            }
        }

        override func layout() {
            super.layout()
            synchronize()
        }

        func stop() {
            active = false
            titleObservation = nil
            visibilityObservation = nil
            toolbarObservation = nil
            centerObservation = nil
            itemOrderObservation = nil
            itemNotifications.forEach(NotificationCenter.default.removeObserver)
            itemNotifications.removeAll()
            observedToolbar = nil
        }
    }

    /// The tracking separator defines the detail column; collapsed sidebars reserve no title space.
    static func titleOrder(_ items: [NSToolbarItem.Identifier], title: NSToolbarItem.Identifier,
                           separator: NSToolbarItem.Identifier?) -> [NSToolbarItem.Identifier] {
        guard items.contains(title) else { return items }
        var ordered = items.filter { $0 != title }
        let index = separator.flatMap { ordered.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        ordered.insert(title, at: index)
        return ordered
    }

    func makeNSView(context _: Context) -> TitleView {
        let view = TitleView()
        view.representedWindowTitle = title
        view.actionTitles = actionTitles
        view.actionIdentifiers = actionIdentifiers
        view.trailingItemIdentifiers = trailingItemIdentifiers
        return view
    }

    func updateNSView(_ view: TitleView, context _: Context) {
        view.representedWindowTitle = title
        view.actionTitles = actionTitles
        view.actionIdentifiers = actionIdentifiers
        view.trailingItemIdentifiers = trailingItemIdentifiers
        view.synchronize()
        view.schedule()
    }

    static func dismantleNSView(_ view: TitleView, coordinator _: ()) {
        view.stop()
    }
}
