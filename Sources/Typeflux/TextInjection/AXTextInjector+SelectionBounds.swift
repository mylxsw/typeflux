import AppKit
import ApplicationServices

extension AXTextInjector {
    /// Optional geometry is presentation context, never evidence authorizing replacement.
    func selectionBounds(element: AXUIElement, range: CFRange?) -> CGRect? {
        guard var range, range.location >= 0, range.length > 0,
              let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success else { return nil }
        return Self.appKitSelectionBounds(result, primaryScreenHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    static func appKitSelectionBounds(_ value: CFTypeRef?, primaryScreenHeight: CGFloat) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let typed = unsafeBitCast(value, to: AXValue.self)
        var bounds = CGRect.zero
        guard AXValueGetType(typed) == .cgRect, AXValueGetValue(typed, .cgRect, &bounds),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return CGRect(x: bounds.minX, y: primaryScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
