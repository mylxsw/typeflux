import Foundation

struct AskFilePreviewPlacement: Equatable {
    enum Side { case left, right }
    var frame: CGRect
    var side: Side

    /// Screen coordinates may be negative. Only the launcher's display is considered.
    static func resolve(card: CGRect, screens: [CGRect]) -> Self? {
        guard let screen = screens.max(by: { area($0.intersection(card)) < area($1.intersection(card)) }),
              screen.intersects(card) else { return nil }
        let right = screen.maxX - card.maxX - 10
        let left = card.minX - screen.minX - 10
        let side: Side
        let width: CGFloat
        if right >= 380 {
            side = .right; width = 380
        } else if left >= 380 {
            side = .left; width = 380
        } else if right >= 280 {
            side = .right; width = min(380, right)
        } else if left >= 280 {
            side = .left; width = min(380, left)
        } else {
            return nil
        }
        let height = max(320, card.height)
        return Self(frame: CGRect(x: side == .right ? card.maxX + 10 : card.minX - width - 10,
                                  y: card.maxY - height, width: width, height: height), side: side)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
