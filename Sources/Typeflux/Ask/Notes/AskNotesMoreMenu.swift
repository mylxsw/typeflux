import AppKit
import SwiftUI

/// Own the native menu and its target inside custom toolbar content, independently of AppKit's toolbar proxies.
struct AskNotesMoreMenu: NSViewRepresentable {
    @ObservedObject var model: AskNotesViewModel
    var compact: Bool
    static let accessibilityIdentifier = "ask.notes.more"

    final class ToolbarView: NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)

        override init(frame: NSRect) {
            super.init(frame: frame)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imagePosition = .imageOnly
            (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            setAccessibilityElement(false)
            setAccessibilityChildren([button])
            button.setAccessibilityElement(true)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder _: NSCoder) { return nil }

        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 28) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureToolbarItem()
            DispatchQueue.main.async { [weak self] in self?.configureToolbarItem() }
        }

        override func layout() {
            super.layout()
            configureToolbarItem()
        }

        private func configureToolbarItem() {
            guard let item = window?.toolbar?.items.first(where: {
                guard let host = $0.view else { return false }
                return host === self || isDescendant(of: host)
            }) else { return }
            if item.visibilityPriority != .high { item.visibilityPriority = .high }
            let title = L("ask.notes.more")
            if item.label != title { item.label = title }
            if item.paletteLabel != title { item.paletteLabel = title }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var model: AskNotesViewModel
        var compact: Bool
        weak var view: ToolbarView?
        var actions: [String: () -> Void] = [:]
        private var tracking = false
        var sharePicker: NSSharingServicePicker?

        init(model: AskNotesViewModel, compact: Bool) {
            self.model = model
            self.compact = compact
            super.init()
        }

        func refresh() {
            guard !tracking, let menu = view?.button.menu else { return }
            populate(menu)
        }

        func menuNeedsUpdate(_ menu: NSMenu) { if !tracking { populate(menu) } }
        func menuWillOpen(_: NSMenu) { tracking = true }
        func menuDidClose(_: NSMenu) {
            tracking = false
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        @objc func activateItem(_ item: NSMenuItem) {
            guard item.isEnabled, let id = item.identifier?.rawValue else { return }
            actions[id]?()
            refresh()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, compact: compact) }

    func makeNSView(context: Context) -> ToolbarView {
        let view = ToolbarView(frame: .zero)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        view.button.menu = menu
        context.coordinator.view = view
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ToolbarView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.compact = compact
        coordinator.view = view
        view.button.isEnabled = context.environment.isEnabled
        view.button.toolTip = L("ask.notes.more")
        view.button.setAccessibilityElement(true)
        view.button.setAccessibilityLabel(L("ask.notes.more"))
        view.button.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        coordinator.refresh()
    }

    static func dismantleNSView(_ view: ToolbarView, coordinator: Coordinator) {
        view.button.menu?.cancelTrackingWithoutAnimation()
        view.button.menu?.delegate = nil
        view.button.menu = nil
        view.button.isEnabled = false
        coordinator.actions.removeAll()
        coordinator.sharePicker = nil
        coordinator.view = nil
    }
}
