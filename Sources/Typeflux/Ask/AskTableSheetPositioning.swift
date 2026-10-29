import AppKit

/// Overrides only this sheet's attachment point; the window's existing delegate keeps all other behavior.
final class AskTableSheetPositioning: NSObject, NSWindowDelegate {
    weak var original: (any NSWindowDelegate)?
    private weak var sheet: NSWindow?

    init(sheet: NSWindow, original: (any NSWindowDelegate)?) {
        self.sheet = sheet
        self.original = original
        super.init()
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        guard sheet === self.sheet else {
            return original?.window?(window, willPositionSheet: sheet, using: rect) ?? rect
        }
        // AppKit uses this point on every placement, including after toolbar layout and resizing.
        return NSRect(x: 0, y: window.frame.height, width: window.frame.width, height: 0)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
