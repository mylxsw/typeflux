import Foundation

/// The app that owned the pasteboard when content was captured.
struct ClipboardSource: Equatable {
    let bundleID: String?
    let appName: String?
}
