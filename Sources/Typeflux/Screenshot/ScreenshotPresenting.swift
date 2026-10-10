import CoreGraphics
import Foundation

enum ScreenshotOutputAction: Equatable {
    case copy
    case save
}

/// What happens in the full-screen overlay, reported to the coordinator.
enum ScreenshotOverlayEvent: Equatable {
    /// A region was chosen; the overlay now adjusts it instead of framing a new one.
    case committed
    /// Use the region with its annotations, both in global Quartz points on one display.
    case finish(ScreenshotOutputAction, displayID: CGDirectDisplayID, rect: CGRect,
                annotations: [ScreenshotAnnotation] = [])
    /// Capture the region (global Quartz points) again while it scrolls.
    case scroll(displayID: CGDirectDisplayID, rect: CGRect)
    /// ⇧ while the loupe shows: the color under the pointer, as hex.
    case colorPicked(String)
    case cancelled
}

/// The frozen displays with the framing interface over them, one panel per display.
@MainActor
protocol ScreenshotOverlayPresenting: AnyObject {
    func present(_ snapshot: ScreenSnapshot, onEvent: @escaping (ScreenshotOverlayEvent) -> Void)
    /// Selects the whole display under the pointer.
    func selectFullScreen()
    /// Hands the chosen region to a scrolling capture (`.scroll`), unless something is marked on it.
    func startScrollCapture()
    /// Closes every panel and lets go of the frozen images. Safe to call when nothing shows.
    func dismiss()
}

/// The short message at the bottom of the screen after a screenshot.
enum ScreenshotToast: Equatable {
    case copied
    case saved(URL)
    /// Saving failed, so the image went to the clipboard; the reason is shown.
    case savedAsCopy(reason: String)
    case colorCopied(String)
    /// The shortcut was pressed while a screenshot was still being taken or saved.
    case busy
    /// A scrolling capture stopped at the size limit.
    case scrollLimitReached
    /// The region did not scroll, so only its first frame was kept.
    case scrollUnavailable
    /// The live capture stopped; what was joined so far is kept.
    case scrollInterrupted
    case failed
}

@MainActor
protocol ScreenshotToastPresenting: AnyObject {
    func show(_ toast: ScreenshotToast)
}

/// What the Screen Recording guide's buttons do.
struct ScreenshotPermissionGuideActions {
    var openSettings: () -> Void
    /// Checks access again; true when it is granted now and the screenshot starts.
    var recheck: () -> Bool
    var restart: () -> Void
    var later: () -> Void
}

@MainActor
protocol ScreenshotPermissionGuidePresenting: AnyObject {
    func show(actions: ScreenshotPermissionGuideActions)
    func dismiss()
}
