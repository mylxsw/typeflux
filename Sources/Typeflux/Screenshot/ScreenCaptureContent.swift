import CoreGraphics
import ScreenCaptureKit

/// What the system can capture right now, reduced to plain values so
/// `ScreenCaptureService` can be tested without Screen Recording access.
struct ScreenCaptureContent {
    struct Display: Equatable {
        var id: CGDirectDisplayID
        var frame: CGRect
        var scale: CGFloat
    }

    var displays: [Display]
    var windows: [ScreenSnapshot.Window]
    /// Captures one display at a pixel size, leaving out the listed windows.
    var capture: (Display, [CGWindowID], ScreenPixelSize) async throws -> CGImage

    /// Reads ScreenCaptureKit. Requires Screen Recording access; callers check it first.
    static func system() async throws -> ScreenCaptureContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return ScreenCaptureContent(
            displays: content.displays.map { display in
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                return Display(id: display.displayID, frame: display.frame,
                               scale: ScreenCaptureGeometry.backingScale(pixelWidth: mode?.pixelWidth ?? 0,
                                                                         pointWidth: mode?.width ?? 0))
            },
            windows: ordered(content.windows.map { window in
                ScreenSnapshot.Window(
                    id: window.windowID, frame: window.frame,
                    processID: window.owningApplication?.processID ?? 0,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    applicationName: window.owningApplication?.applicationName,
                    title: window.title, layer: window.windowLayer
                )
            }, frontToBack: onScreenWindowOrder()),
            capture: { display, excluded, size in
                guard let target = content.displays.first(where: { $0.displayID == display.id }) else {
                    throw ScreenCaptureError.unavailable
                }
                let excludedWindows = content.windows.filter { excluded.contains($0.windowID) }
                let filter = SCContentFilter(display: target, excludingWindows: excludedWindows)
                let config = SCStreamConfiguration()
                config.width = size.width
                config.height = size.height
                config.showsCursor = false
                if #available(macOS 14.0, *) {
                    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                }
                guard let legacy = CGWindowListCreateImage(CGDisplayBounds(target.displayID), .optionOnScreenOnly,
                                                           kCGNullWindowID, .bestResolution) else {
                    throw ScreenCaptureError.unavailable
                }
                return legacy
            }
        )
    }

    /// ScreenCaptureKit does not promise an order; the window server's list is front to back.
    static func ordered(_ windows: [ScreenSnapshot.Window],
                        frontToBack order: [CGWindowID]) -> [ScreenSnapshot.Window] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max, right = rank[rhs.element.id] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private static func onScreenWindowOrder() -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }
}
