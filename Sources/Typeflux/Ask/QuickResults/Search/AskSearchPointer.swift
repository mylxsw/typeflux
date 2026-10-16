import Foundation

/// A result arriving under a stationary pointer must not replace a keyboard
/// selection. Only actual pointer motion can move the highlight.
///
/// A reference type on purpose: views keep it in `@State`, and recording each
/// pointer position must not invalidate the list on every mouse movement.
final class AskSearchPointer {
    var position: CGPoint

    init(position: CGPoint) {
        self.position = position
    }

    func moved(to point: CGPoint) -> Bool {
        guard point != position else { return false }
        position = point
        return true
    }
}
