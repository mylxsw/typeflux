import AppKit
import SwiftUI

/// `orderOut` retains the hosting view, so SwiftUI's `onDisappear` alone cannot
/// stop an empty chat's animation. Follow the actual window's visible region.
struct AskOrbVisibility: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context _: Context) {
        view.onChange = onChange
    }

    class VisibilityView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var reported: Bool?

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                          object: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                      name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            visibilityChanged()
        }

        override func viewDidHide() {
            super.viewDidHide()
            visibilityChanged()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            visibilityChanged()
        }

        @objc private func visibilityChanged() {
            // Window attachment can happen during a SwiftUI update. Publish on
            // the next turn, reading current state so stale notifications cannot
            // restart an animation after its window has been hidden or detached.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
                    && !isHiddenOrHasHiddenAncestor
                guard visible != reported else { return }
                reported = visible
                onChange(visible)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
