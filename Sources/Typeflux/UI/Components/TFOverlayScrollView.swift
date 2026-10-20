import AppKit

/// Keeps native editors on overlay scrollers when macOS changes its preferred style.
final class TFOverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}
