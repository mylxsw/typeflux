import CoreGraphics
import Foundation

/// How a scrolling capture ended with an image.
enum ScrollCaptureEnding: Equatable {
    /// ↩ or the Done button.
    case user
    /// Several automatic scrolls in a row changed nothing: the bottom or right edge.
    case reachedEnd
    case reachedLimit
    /// The region never scrolled; only the first frame is there.
    case cannotScroll
    /// The stream stopped (a display went away, the window closed); what was joined so far is kept.
    case interrupted
}

enum ScrollCaptureResult {
    case finished(CGImage, ScrollCaptureEnding)
    case cancelled
    /// Nothing was captured.
    case failed
}

/// What the bar under the region shows.
struct ScrollCaptureViewState: Equatable {
    enum Status: Equatable {
        /// Waiting for the first frame.
        case starting
        case scrolling
        /// The default: only the user scrolls the region.
        case manual
        /// ␣ paused it; the user can scroll by hand.
        case paused
        /// The user used the mouse, so automatic scrolling stepped aside.
        case pausedByMouse
        /// Several frames in a row did not line up; scrolling by hand from here.
        case misaligned
        /// No Accessibility access: only scrolling by hand.
        case needsAccessibility
    }

    var status: Status = .starting
    var pixelSize = ScreenPixelSize(width: 0, height: 0)
    var axis: ScrollCaptureAxis = .vertical
    var canUndo = false
    /// The newest segment did not line up well.
    var lastSegmentSuspicious = false

    var isAutomatic: Bool {
        status == .scrolling
    }

    /// Accessibility is requested only after the user asks to start automatic scrolling.
    var canToggleAutomatic: Bool {
        status != .starting
    }
}

/// The stitched image so far, for the preview strip.
struct ScrollCapturePreview {
    var axis: ScrollCaptureAxis = .vertical
    var segments: [ScrollStitcher.Segment] = []
    var footer: CGImage?
    /// The fixed top bar's height, or the fixed left bar's width for a horizontal capture.
    var headerHeight = 0
    var width = 0
}

/// The buttons and keys of the scrolling capture bar.
struct ScrollCaptureActions {
    var togglePause: () -> Void
    var undo: () -> Void
    var cancel: () -> Void
    var finish: () -> Void
    var openAccessibilitySettings: () -> Void
}

/// The dimmed surroundings, the region's outline, the bar and the preview.
@MainActor
protocol ScrollCapturePresenting: AnyObject {
    func present(_ region: ScrollCaptureRegion, actions: ScrollCaptureActions)
    func update(_ state: ScrollCaptureViewState, preview: ScrollCapturePreview)
    func dismiss()
}

/// The scrolling capture that `ScreenshotCoordinator` runs.
@MainActor
protocol ScrollCapturing: AnyObject {
    func start(onFinish: @escaping (ScrollCaptureResult) -> Void)
    func cancel()
}
