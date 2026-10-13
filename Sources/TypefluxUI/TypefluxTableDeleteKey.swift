import AppKit
import SwiftUI

/// AppKit-hosted windows do not always install SwiftUI's Edit menu commands.
/// Handle unmodified Delete only while this table, rather than a text editor, owns focus.
struct TypefluxTableDeleteKey: NSViewRepresentable {
    let action: (() -> Void)?
    let tableIdentifier: String

    final class KeyView: NSView {
        var action: (() -> Void)?
        var tableIdentifier: String?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, handle(event) else { return event }
                return nil
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            guard let action, let window, event.window === window, window.attachedSheet == nil,
                  event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
                  let focused = window.firstResponder as? NSView, !(focused is NSTextView),
                  let table = table(), !table.selectedRowIndexes.isEmpty,
                  focused === table || focused.isDescendant(of: table) else { return false }
            action()
            return true
        }

        private func table() -> NSTableView? {
            var ancestor = superview
            while let view = ancestor {
                let tables = descendants(view).compactMap { $0 as? NSTableView }.filter {
                    if let tableIdentifier {
                        return $0.accessibilityIdentifier() == tableIdentifier
                    }
                    return !($0 is NSOutlineView)
                }
                if tables.count == 1 {
                    return tables.first
                }
                if tables.count > 1 {
                    return nil
                }
                ancestor = view.superview
            }
            return nil
        }

        private func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeNSView(context _: Context) -> KeyView {
        let view = KeyView()
        view.action = action
        view.tableIdentifier = tableIdentifier
        return view
    }

    func updateNSView(_ view: KeyView, context _: Context) {
        view.action = action
        view.tableIdentifier = tableIdentifier
    }

    static func dismantleNSView(_ view: KeyView, coordinator _: ()) {
        view.stop()
    }
}
