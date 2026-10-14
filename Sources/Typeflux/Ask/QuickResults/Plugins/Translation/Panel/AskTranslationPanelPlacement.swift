import AppKit

/// All coordinates are AppKit screen points. Visible frames exclude the menu bar and Dock.
enum AskTranslationPanelPlacement {
    static let width: CGFloat = 452

    static func frame(size: CGSize, screen: CGRect, position: AskTranslationPanelPosition,
                      mouse: CGPoint, last: CGPoint? = nil, selection: CGRect? = nil) -> CGRect {
        let size = CGSize(width: min(max(1, size.width), screen.width),
                          height: min(max(1, size.height), screen.height))
        let origin: CGPoint
        if let selection {
            let below = selection.minY - 8 - size.height
            origin = CGPoint(x: selection.minX, y: below >= screen.minY ? below : selection.maxY + 8)
        } else {
            switch position {
            case .center: origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
            case .mouse: origin = CGPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
            case .lastPosition: origin = last ?? CGPoint(
                    x: screen.midX - size.width / 2,
                    y: screen.midY - size.height / 2
                )
            }
        }
        return CGRect(x: min(max(screen.minX, origin.x), screen.maxX - size.width),
                      y: min(max(screen.minY, origin.y), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func height(content: CGFloat, screen: CGRect, preference: AskTranslationPanelHeight) -> CGFloat {
        min(max(1, content), screen.height * preference.fraction)
    }
}
