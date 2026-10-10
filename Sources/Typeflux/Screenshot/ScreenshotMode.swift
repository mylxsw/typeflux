import Foundation

/// How a screenshot starts: the user frames a region, the whole display under the pointer is taken,
/// or the framed region goes straight to a scrolling capture.
enum ScreenshotMode: String, CaseIterable, Equatable, Sendable {
    case region
    case fullScreen
    case scrolling

    /// The launcher keyword option that picks a mode (`jtqp` → `fullScreen`, `jtgd` → `scrolling`).
    static let option = "mode"

    init(options: [String: String]) {
        self = options[Self.option].flatMap(Self.init(rawValue:)) ?? .region
    }
}
