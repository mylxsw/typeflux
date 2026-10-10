import CoreGraphics

/// Where the scrolling capture's panels go, in global Quartz points. Nothing is placed over the
/// region itself except the outline, which lets every event through, so the wheel reaches the app.
enum ScrollCaptureLayout {
    static let gap: CGFloat = 10
    static let margin: CGFloat = 8
    static let outlineWidth: CGFloat = 2
    static let previewWidth: CGFloat = 132
    static let minimumPreviewHeight: CGFloat = 160

    /// The four dimmed panels above, below, left and right of the region; empty ones are left out.
    static func dimRects(around region: CGRect, in display: CGRect) -> [CGRect] {
        let region = region.intersection(display)
        guard !region.isNull else { return [display] }
        return [
            CGRect(x: display.minX, y: display.minY, width: display.width, height: region.minY - display.minY),
            CGRect(x: display.minX, y: region.maxY, width: display.width, height: display.maxY - region.maxY),
            CGRect(x: display.minX, y: region.minY, width: region.minX - display.minX, height: region.height),
            CGRect(x: region.maxX, y: region.minY, width: display.maxX - region.maxX, height: region.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// The outline just outside the region.
    static func outlineRect(around region: CGRect) -> CGRect {
        region.insetBy(dx: -outlineWidth, dy: -outlineWidth)
    }

    /// Centered under the region; above it when there is no room below; inside its bottom edge otherwise.
    static func barFrame(size: CGSize, region: CGRect, display: CGRect) -> CGRect {
        let left = min(max(region.midX - size.width / 2, display.minX + margin),
                    display.maxX - margin - size.width)
        let below = region.maxY + gap
        if below + size.height <= display.maxY - margin {
            return CGRect(x: left, y: below, width: size.width, height: size.height)
        }
        let above = region.minY - gap - size.height
        if above >= display.minY + margin {
            return CGRect(x: left, y: above, width: size.width, height: size.height)
        }
        return CGRect(x: left, y: region.maxY - margin - size.height, width: size.width, height: size.height)
    }

    /// Right of the region; left of it when there is no room; inside its right edge otherwise.
    static func previewFrame(region: CGRect, display: CGRect) -> CGRect {
        let height = min(max(region.height, minimumPreviewHeight), display.height - margin * 2)
        let top = min(max(region.minY, display.minY + margin), display.maxY - margin - height)
        let right = region.maxX + gap
        if right + previewWidth <= display.maxX - margin {
            return CGRect(x: right, y: top, width: previewWidth, height: height)
        }
        let left = region.minX - gap - previewWidth
        if left >= display.minX + margin {
            return CGRect(x: left, y: top, width: previewWidth, height: height)
        }
        return CGRect(x: region.maxX - margin - previewWidth, y: top, width: previewWidth, height: height)
    }
}
