import CoreGraphics
import Foundation

/// The region being framed on one display, and how the pointer and keys change it.
/// Pure geometry: coordinates are the display's own points with the origin at its
/// top-left corner and y growing downward, as in the overlay's flipped view.
/// Every rectangle stays on whole points inside the display.
struct ScreenshotSelection: Equatable {
    enum Handle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    enum Hit: Equatable {
        case handle(Handle)
        case inside
        case outside
    }

    /// What an input did, for the overlay to redraw and the coordinator to follow.
    enum Outcome: Equatable {
        case none
        case changed
        /// A region was chosen: the first one, or a new one replacing it.
        case committed
        /// Double-click inside the region: use it as it is.
        case confirmed
    }

    private enum Drag: Equatable {
        case creating(anchor: CGPoint, current: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect)
    }

    /// A press that moves less than this is a click, which picks the window under it.
    static let clickTolerance: CGFloat = 3
    static let handleHitRadius: CGFloat = 6
    static let nudgeStep: CGFloat = 1
    static let largeNudgeStep: CGFloat = 10
    /// Window levels that can be snapped to: normal, floating and modal windows, not
    /// the Dock, menu bar or screen-wide overlays above them.
    static let snappableLayers = 0 ..< 20
    static let excludedBundleIdentifiers: Set<String> = ["com.apple.dock", "com.apple.WindowManager"]

    /// The display's own area: origin zero, its size in points.
    let bounds: CGRect
    let scale: CGFloat
    /// Snappable windows on this display, front to back, clipped to it.
    let windows: [CGRect]
    private(set) var rect: CGRect?
    /// The window under the pointer, while nothing is selected yet.
    private(set) var hovered: CGRect?
    private(set) var pointer: CGPoint?
    private var drag: Drag?

    /// - Parameters:
    ///   - displayFrame: the display in global Quartz points.
    ///   - windows: the snapshot's windows, front to back, in global Quartz points.
    init(displayFrame: CGRect, scale: CGFloat, windows: [ScreenSnapshot.Window]) {
        bounds = CGRect(origin: .zero, size: displayFrame.size)
        self.scale = max(scale, 1)
        let local = CGRect(origin: .zero, size: displayFrame.size)
        self.windows = windows.compactMap { window -> CGRect? in
            guard Self.snappableLayers.contains(window.layer),
                  !Self.excludedBundleIdentifiers.contains(window.bundleIdentifier ?? ""),
                  !Self.isInvisibleOverlay(window, on: displayFrame) else { return nil }
            let clipped = window.frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
                .intersection(local).integral
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
            return clipped
        }
    }

    /// An untitled window covering the whole display is a transparent overlay (a cursor
    /// highlighter, a screen dimmer), not something to frame; ⌘A takes the display anyway.
    static func isInvisibleOverlay(_ window: ScreenSnapshot.Window, on displayFrame: CGRect) -> Bool {
        (window.title ?? "").isEmpty && window.frame.contains(displayFrame)
    }

    var isDragging: Bool { drag != nil }

    /// What the overlay outlines: the selection, or the window that a click would pick.
    var highlighted: CGRect? { rect ?? hovered }

    /// The selection's size in the display's pixels.
    var pixelSize: ScreenPixelSize? {
        rect.map { ScreenPixelSize(width: Int(($0.width * scale).rounded()),
                                   height: Int(($0.height * scale).rounded())) }
    }

    /// "640 × 480 pt · 1280 × 960 px"; the points alone on a 1× display.
    var sizeLabel: String? {
        guard let size = highlighted?.size else { return nil }
        let points = "\(Int(size.width)) × \(Int(size.height))"
        guard scale > 1 else { return points }
        let pixels = "\(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded()))"
        return "\(points) pt · \(pixels) px"
    }

    /// The front-most window under a point.
    func window(at point: CGPoint) -> CGRect? {
        windows.first { $0.contains(point) }
    }

    func hit(at point: CGPoint) -> Hit {
        guard let rect else { return .outside }
        for handle in Handle.allCases {
            let anchor = Self.point(for: handle, in: rect)
            if hypot(anchor.x - point.x, anchor.y - point.y) <= Self.handleHitRadius { return .handle(handle) }
        }
        return rect.contains(point) ? .inside : .outside
    }

    // MARK: Pointer

    mutating func pointerMoved(to point: CGPoint) {
        let point = clamped(point)
        pointer = point
        hovered = rect == nil && drag == nil ? window(at: point) : nil
    }

    mutating func pointerExited() {
        pointer = nil
        if drag == nil { hovered = nil }
    }

    mutating func mouseDown(at point: CGPoint, clickCount: Int = 1) -> Outcome {
        let point = clamped(point)
        pointer = point
        if clickCount >= 2, let rect, rect.contains(point) {
            drag = nil
            return .confirmed
        }
        switch hit(at: point) {
        case let .handle(handle):
            drag = .resizing(handle, original: rect ?? bounds)
        case .inside:
            drag = .moving(start: point, original: rect ?? bounds)
        case .outside:
            drag = .creating(anchor: point, current: point)
        }
        return .none
    }

    /// - Parameter movesSelection: space is held, so the region moves instead of growing.
    mutating func mouseDragged(to point: CGPoint, movesSelection: Bool = false) -> Outcome {
        let point = clamped(point)
        pointer = point
        hovered = nil
        switch drag {
        case var .creating(anchor, current):
            if movesSelection {
                let size = CGSize(width: current.x - anchor.x, height: current.y - anchor.y)
                let moved = translated(Self.rect(from: anchor, to: current),
                                       by: CGSize(width: point.x - current.x, height: point.y - current.y))
                // Keep the drag's direction: the anchor stays the corner it started as.
                anchor = CGPoint(x: size.width >= 0 ? moved.minX : moved.maxX,
                                 y: size.height >= 0 ? moved.minY : moved.maxY)
                current = CGPoint(x: anchor.x + size.width, y: anchor.y + size.height)
            } else {
                current = point
            }
            drag = .creating(anchor: anchor, current: current)
            rect = Self.isClick(from: anchor, to: current) ? nil : Self.snapped(Self.rect(from: anchor, to: current))
            return .changed
        case let .moving(start, original):
            rect = translated(original, by: CGSize(width: point.x - start.x, height: point.y - start.y))
            return .changed
        case let .resizing(handle, original):
            rect = Self.resized(original, handle: handle, to: point, within: bounds)
            return .changed
        case nil:
            return .none
        }
    }

    mutating func mouseUp(at point: CGPoint) -> Outcome {
        let point = clamped(point)
        defer { drag = nil }
        switch drag {
        case let .creating(anchor, current):
            if Self.isClick(from: anchor, to: current) {
                // A click picks the window under it, or the whole display between windows.
                rect = window(at: point) ?? bounds
            }
            hovered = nil
            return .committed
        case .moving, .resizing:
            return .changed
        case nil:
            return .none
        }
    }

    // MARK: Keys

    /// ⌘A, or the shortcut pressed again while framing.
    mutating func selectAll() -> Outcome {
        drag = nil
        hovered = nil
        rect = bounds
        return .committed
    }

    mutating func clear() {
        drag = nil
        rect = nil
        hovered = pointer.flatMap(window(at:))
    }

    /// Arrow keys: one point, or ten with ⇧.
    mutating func nudge(by offset: CGSize) -> Outcome {
        guard let rect, drag == nil else { return .none }
        let moved = translated(rect, by: offset)
        guard moved != rect else { return .none }
        self.rect = moved
        return .changed
    }

    // MARK: Geometry

    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        abs(end.x - start.x) < clickTolerance && abs(end.y - start.y) < clickTolerance
    }

    static func point(for handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Moves the edges a handle holds to `point`. Dragging past the opposite edge
    /// flips the region instead of collapsing it; it never leaves `bounds` or drops below one point.
    static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint, within bounds: CGRect) -> CGRect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        switch handle {
        case .topLeft: left = point.x; top = point.y
        case .top: top = point.y
        case .topRight: right = point.x; top = point.y
        case .right: right = point.x
        case .bottomRight: right = point.x; bottom = point.y
        case .bottom: bottom = point.y
        case .bottomLeft: left = point.x; bottom = point.y
        case .left: left = point.x
        }
        var result = Self.rect(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: bottom))
            .intersection(bounds)
        if result.isNull { result = CGRect(origin: clamp(point, to: bounds), size: .zero) }
        result = snapped(result)
        result.size.width = max(result.width, 1)
        result.size.height = max(result.height, 1)
        result.origin.x = min(result.minX, bounds.maxX - result.width)
        result.origin.y = min(result.minY, bounds.maxY - result.height)
        return result
    }

    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// Whole points, rounded to the nearest edge.
    static func snapped(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(), minY = rect.minY.rounded()
        return CGRect(x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        Self.clamp(point, to: bounds)
    }

    /// Moves a region as far as `delta` allows without leaving the display.
    private func translated(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let snappedRect = Self.snapped(rect)
        let originX = min(max(snappedRect.minX + delta.width.rounded(), bounds.minX), bounds.maxX - snappedRect.width)
        let originY = min(max(snappedRect.minY + delta.height.rounded(), bounds.minY),
                          bounds.maxY - snappedRect.height)
        return CGRect(x: originX, y: originY, width: snappedRect.width, height: snappedRect.height)
    }
}
