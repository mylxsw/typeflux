import AppKit
import SwiftUI

/// Keep window metadata while the visible title leads the detail toolbar.
/// SwiftUI restores title visibility and centers principal items during toolbar updates.
struct TypefluxWindowTitleBridge: NSViewRepresentable {
    static let itemIdentifier = "typeflux.window.title"
    let title: String

    final class TitleView: NSView {
        var title = ""
        private var active = false
        private var titleObservation: NSKeyValueObservation?
        private var visibilityObservation: NSKeyValueObservation?
        private var toolbarObservation: NSKeyValueObservation?
        private var centerObservation: NSKeyValueObservation?
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
            guard active, let window else { return }
            if window.title != title { window.title = title }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if observedToolbar !== window.toolbar {
                centerObservation = nil
                observedToolbar = window.toolbar
                centerObservation = window.toolbar?.observe(\.centeredItemIdentifiers) { [weak self] _, _ in
                    self?.schedule()
                }
            }
            if let toolbar = window.toolbar {
                let identifier = NSToolbarItem.Identifier(TypefluxWindowTitleBridge.itemIdentifier)
                if toolbar.centeredItemIdentifiers.contains(identifier) {
                    toolbar.centeredItemIdentifiers.remove(identifier)
                }
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
            observedToolbar = nil
        }
    }

    func makeNSView(context _: Context) -> TitleView {
        let view = TitleView()
        view.title = title
        return view
    }

    func updateNSView(_ view: TitleView, context _: Context) {
        view.title = title
        view.synchronize()
        view.schedule()
    }

    static func dismantleNSView(_ view: TitleView, coordinator _: ()) {
        view.stop()
    }
}
