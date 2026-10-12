import AppKit
import SwiftUI

/// Custom AppKit-hosted windows need their title updated as well as SwiftUI's toolbar title.
struct TypefluxWindowTitleBridge: NSViewRepresentable {
    let title: String

    final class TitleView: NSView {
        var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.title = title
        }
    }

    func makeNSView(context _: Context) -> TitleView {
        let view = TitleView()
        view.title = title
        return view
    }

    func updateNSView(_ view: TitleView, context _: Context) {
        view.title = title
        if view.window?.title != title {
            view.window?.title = title
        }
    }
}
