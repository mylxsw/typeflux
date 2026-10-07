import Foundation

/// A result arriving under a stationary pointer must not replace a keyboard
/// selection. Only actual pointer motion can move the highlight.
struct AskSearchPointer {
    var position: CGPoint

    mutating func moved(to point: CGPoint) -> Bool {
        guard point != position else { return false }
        position = point
        return true
    }
}
