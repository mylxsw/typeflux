import AppKit

extension NSBezierPath {
    /// `cgPath` needs macOS 14; Typeflux still supports macOS 13.
    var compatibleCGPath: CGPath {
        if #available(macOS 14.0, *) { return cgPath }
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .closePath: path.closeSubpath()
            // Quadratic segments only exist on macOS 14, which takes the branch above.
            default: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            }
        }
        return path
    }
}
