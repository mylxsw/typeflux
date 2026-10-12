import AppKit
import SwiftUI

/// Observes the native search field without replacing SwiftUI's delegate or target/action.
struct TypefluxSearchToolbarBridge: NSViewRepresentable {
    var state: TypefluxSearchState
    var style: InterfaceStyle

    final class BridgeView: NSView {
        var state: TypefluxSearchState?
        var style: InterfaceStyle = .classic
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var synchronizing = false
        private var widthConstraint: NSLayoutConstraint?
        private weak var constrainedField: NSSearchField?
        private var searchItem: NSSearchToolbarItem? {
            window?.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
                let observer = NotificationCenter.default
                    .addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                        MainActor.assumeIsolated {
                            guard let self, !self.synchronizing,
                                  let field = notification.object as? NSSearchField,
                                  let item = self.searchItem, field === item.searchField else { return }
                            self.state?.focusChanged(name == NSControl.textDidBeginEditingNotification)
                            self.synchronize()
                        }
                    }
                observers.append(observer)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, event.window === window,
                      window.attachedSheet == nil else { return event }
                return handle(event) ? nil : event
            }
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }

        override func layout() {
            super.layout()
            synchronize()
        }

        func handle(_ event: NSEvent) -> Bool {
            guard let state, let item = searchItem else { return false }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
                state.expand()
                synchronize()
                if item.searchField.currentEditor() == nil {
                    item.beginSearchInteraction()
                }
                return true
            }
            if flags.isEmpty, event.keyCode == 53, let editor = item.searchField.currentEditor() as? NSTextView,
               !editor.hasMarkedText(), state.escape() {
                synchronize()
                return true
            }
            return false
        }

        func synchronize() {
            guard !synchronizing, let state, let item = searchItem else { return }
            synchronizing = true
            defer { synchronizing = false }
            item.resignsFirstResponderWithCancel = false
            item.preferredWidthForSearchField = TypefluxControlWidth.toolbarSearch.value(for: style)
            let width = state.isExpanded ? item.preferredWidthForSearchField
                : TypefluxControlWidth.toolbarItem.value(for: style)
            if constrainedField !== item.searchField {
                widthConstraint?.isActive = false
                let constraint = item.searchField.widthAnchor.constraint(equalToConstant: width)
                constraint.priority = .defaultHigh
                constraint.isActive = true
                widthConstraint = constraint
                constrainedField = item.searchField
            }
            widthConstraint?.constant = width
            if item.searchField.stringValue != state.query {
                item.searchField.stringValue = state.query
            }
            if state.isFocused, item.searchField.currentEditor() == nil, window?.isKeyWindow == true {
                item.beginSearchInteraction()
            } else if !state.isFocused, state.query.isEmpty, item.searchField.currentEditor() != nil {
                item.endSearchInteraction()
            }
        }

        func stop() {
            widthConstraint?.isActive = false
            widthConstraint = nil
            constrainedField = nil
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeNSView(context _: Context) -> BridgeView {
        let view = BridgeView()
        view.state = state
        view.style = style
        return view
    }

    func updateNSView(_ view: BridgeView, context _: Context) {
        view.state = state
        view.style = style
        DispatchQueue.main.async { [weak view] in view?.synchronize() }
    }

    static func dismantleNSView(_ view: BridgeView, coordinator _: ()) {
        view.stop()
    }
}
