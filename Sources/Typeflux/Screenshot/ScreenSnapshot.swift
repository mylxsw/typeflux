import CoreGraphics
import Foundation

/// Every requested display frozen at one moment, plus the on-screen windows at that
/// moment. Frames use global Quartz coordinates in points: the origin is the top-left
/// corner of the primary display and y grows downward.
struct ScreenSnapshot {
    struct Display {
        var id: CGDirectDisplayID
        var frame: CGRect
        /// The display's backing scale factor (pixels per point).
        var scale: CGFloat
        /// The captured image; its size depends on the requested resolution.
        var image: CGImage

        var pixelSize: ScreenPixelSize { ScreenPixelSize(width: image.width, height: image.height) }
    }

    struct Window: Equatable {
        var id: CGWindowID
        var frame: CGRect
        var processID: pid_t
        var bundleIdentifier: String?
        var applicationName: String?
        var title: String?
        /// The window level; normal application windows sit on layer 0.
        var layer: Int
    }

    var displays: [Display]
    /// On-screen windows, never including Typeflux's own.
    var windows: [Window]

    func display(containing point: CGPoint) -> Display? {
        displays.first { $0.frame.contains(point) }
    }

    func display(id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }
}

struct ScreenPixelSize: Equatable {
    var width: Int
    var height: Int
}
