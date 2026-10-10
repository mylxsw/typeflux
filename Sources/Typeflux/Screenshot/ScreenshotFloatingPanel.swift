import AppKit

/// A transparent borderless panel above other apps on every Space.
final class ScreenshotFloatingPanel: NSPanel {
    private let becomesKey: Bool

    init(frame: CGRect, becomesKey: Bool = false) {
        self.becomesKey = becomesKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { becomesKey }
    override var canBecomeMain: Bool { false }
}
