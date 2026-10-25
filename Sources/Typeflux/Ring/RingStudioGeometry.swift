import AppKit
import SwiftUI

/// Geometry shared by the settings preview and its hit testing. Proportions follow OpieMenu
/// (outer radius 128, hole 54, centre disc 48).
struct RingPreviewGeometry: Equatable {
    var size: CGFloat
    var count: Int

    var center: CGPoint {
        CGPoint(x: size / 2, y: size / 2)
    }

    var outerRadius: CGFloat {
        size * 0.30
    }

    var innerRadius: CGFloat {
        outerRadius * 54 / 128
    }

    var centerRadius: CGFloat {
        outerRadius * 48 / 128
    }

    var labelRadius: CGFloat {
        outerRadius + size * 0.10
    }

    /// Angle of slice `index` in screen coordinates (y down), 0 at the top, clockwise.
    func angle(of index: Int) -> CGFloat {
        CGFloat(index) * 2 * .pi / CGFloat(max(count, 1)) - .pi / 2
    }

    func point(at radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// The slice under `location`, or nil in the middle and far outside.
    func index(at location: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let deltaX = location.x - center.x
        let deltaY = location.y - center.y
        let distance = hypot(deltaX, deltaY)
        guard distance >= innerRadius, distance <= labelRadius + size * 0.06 else { return nil }
        var clockwise = atan2(deltaY, deltaX) + .pi / 2
        if clockwise < 0 {
            clockwise += 2 * .pi
        }
        let sector = 2 * .pi / CGFloat(count)
        return Int((clockwise / sector).rounded()) % count
    }

    /// Whether `location` is on the centre disc, which switches between app and global actions.
    func isInCenter(_ location: CGPoint) -> Bool {
        hypot(location.x - center.x, location.y - center.y) <= centerRadius
    }

    /// Where ⊕ sits for inserting at `index`: on the rim, between slice `index - 1` and `index`.
    func insertionPoint(for index: Int) -> CGPoint {
        point(at: outerRadius, angle: angle(of: index - 1) + .pi / CGFloat(max(count, 1)))
    }

    /// The slice index a drag at `location` points to, from the angle alone.
    func nearestIndex(to location: CGPoint) -> Int {
        guard count > 0 else { return 0 }
        var clockwise = atan2(location.y - center.y, location.x - center.x) + .pi / 2
        if clockwise < 0 {
            clockwise += 2 * .pi
        }
        return Int((clockwise / (2 * .pi / CGFloat(count))).rounded()) % count
    }
}

/// One annular sector of the ring.
struct RingSectorShape: Shape {
    var geometry: RingPreviewGeometry
    var index: Int

    func path(in _: CGRect) -> Path {
        let half = .pi / CGFloat(max(geometry.count, 1))
        let middle = geometry.angle(of: index)
        var path = Path()
        path.addArc(center: geometry.center, radius: geometry.outerRadius, startAngle: .radians(middle - half),
                    endAngle: .radians(middle + half), clockwise: false)
        path.addArc(center: geometry.center, radius: geometry.innerRadius, startAngle: .radians(middle + half),
                    endAngle: .radians(middle - half), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// A slice's icon: the app's own icon for apps, otherwise its symbol.
struct RingActionIcon: View {
    let action: RingAction
    var size: CGFloat

    var body: some View {
        if let image = Self.appIcon(for: action) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size * 1.25, height: size * 1.25)
        } else {
            Image(systemName: action.symbol).font(.system(size: size, weight: .medium))
        }
    }

    static func appIcon(for action: RingAction) -> NSImage? {
        guard case let .app(bundleIdentifier, _) = action.kind,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
