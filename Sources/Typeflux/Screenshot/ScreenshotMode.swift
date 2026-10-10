import Foundation

/// How a screenshot starts: the user frames a region, or the whole display under the pointer is taken.
enum ScreenshotMode: String, CaseIterable, Equatable, Sendable {
    case region
    case fullScreen

    /// The launcher keyword option that picks a mode (`jtqp` → `fullScreen`).
    static let option = "mode"

    init(options: [String: String]) {
        self = options[Self.option].flatMap(Self.init(rawValue:)) ?? .region
    }
}
