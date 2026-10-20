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
        worksWhenModal = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    var onHide: (() -> Void)?
    override func orderOut(_ sender: Any?) { onHide?(); super.orderOut(sender) }
    override func close() { onHide?(); super.close() }

    override var canBecomeKey: Bool { becomesKey }
    override var canBecomeMain: Bool { false }
}
