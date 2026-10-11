import CoreGraphics

/// Takes the shake out of a freehand stroke: drops points that add nothing (Ramer–Douglas–Peucker),
/// then runs a Catmull-Rom curve through the rest. Pure, so the editor applies it once a stroke ends.
enum ScreenshotStrokeSmoothing {
    /// Points closer than this to the simplified line are dropped, in points.
    static let tolerance: CGFloat = 1.5
    /// Points sampled along each curve segment.
    static let samplesPerSegment = 6

    static func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        let kept = simplified(points, tolerance: tolerance)
        guard kept.count > 2 else { return kept }
        var result = [kept[0]]
        for index in 0 ..< kept.count - 1 {
            let p0 = kept[max(index - 1, 0)], p1 = kept[index]
            let p2 = kept[index + 1], p3 = kept[min(index + 2, kept.count - 1)]
            for step in 1 ... samplesPerSegment {
                result.append(catmullRom(p0, p1, p2, p3, t: CGFloat(step) / CGFloat(samplesPerSegment)))
            }
        }
        return result
    }

    /// The points that keep the stroke within `tolerance` of its shape; the ends always stay.
    static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        // An explicit stack instead of recursion, so a long stroke cannot overflow it.
        var ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, distance: CGFloat = 0
            for index in first + 1 ..< last {
                let current = ScreenshotAnnotation.distance(from: points[index], toSegment: points[first], points[last])
                if current > distance { (farthest, distance) = (index, current) }
            }
            guard distance > tolerance else { continue }
            keep[farthest] = true
            ranges.append((first, farthest))
            ranges.append((farthest, last))
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// The uniform Catmull-Rom point between `p1` (t = 0) and `p2` (t = 1).
    static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }
}
