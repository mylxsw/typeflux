import Foundation

/// Read access to a pasteboard, abstracted so the monitor can be tested without `NSPasteboard`.
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    func readContents() -> PasteboardContents
}
