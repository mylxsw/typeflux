import AppKit

/// All coordinates are AppKit screen points. Visible frames exclude the menu bar and Dock.
enum AskTranslationPanelPlacement {
    static let width: CGFloat = AskMetrics.launcherWidth
    static let minimumSize = CGSize(width: 520, height: 300)

    /// A remembered height is the user's viewport limit; short content still fits naturally.
    static func size(content: CGFloat, screen: CGRect, preference: AskTranslationPanelHeight,
                     remembered: CGSize? = nil) -> CGSize {
        let proposed = remembered ?? CGSize(width: Self.width, height: screen.height)
        let preferredWidth = proposed.width.isFinite ? proposed.width : Self.width
        let limit = proposed.height.isFinite ? proposed.height : screen.height
        return CGSize(width: min(screen.width, max(minimumSize.width, preferredWidth)),
                      height: height(content: max(minimumSize.height, min(content, max(minimumSize.height, limit))),
                                     screen: screen, preference: preference))
    }

    static func frame(size: CGSize, screen: CGRect, position: AskTranslationPanelPosition,
                      mouse: CGPoint, last: CGPoint? = nil) -> CGRect {
        let size = CGSize(width: min(max(1, size.width), screen.width),
                          height: min(max(1, size.height), screen.height))
        let origin: CGPoint = switch position {
        case .center: CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        case .mouse: CGPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        case .lastPosition: last ?? CGPoint(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2
            )
        }
        return CGRect(x: min(max(screen.minX, origin.x), screen.maxX - size.width),
                      y: min(max(screen.minY, origin.y), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func height(content: CGFloat, screen: CGRect, preference: AskTranslationPanelHeight) -> CGFloat {
        min(max(1, content), screen.height * preference.fraction)
    }
}
