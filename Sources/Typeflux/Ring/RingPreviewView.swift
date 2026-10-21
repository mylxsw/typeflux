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
        if clockwise < 0 { clockwise += 2 * .pi }
        let sector = 2 * .pi / CGFloat(count)
        return Int((clockwise / sector).rounded()) % count
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

/// The ring as it will look, in Settings → Ring. Hovering a slice highlights it; clicking edits it.
struct RingPreviewView: View {
    let actions: [RingAction]
    let style: RingStyle
    let centerTitle: String
    @Binding var highlighted: UUID?
    var onSelect: (UUID) -> Void = { _ in }

    private static let warm = Color(red: 1, green: 0.77, blue: 0.34)

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingPreviewGeometry(size: min(proxy.size.width, proxy.size.height), count: actions.count)
            ZStack {
                if actions.isEmpty {
                    Circle().strokeBorder(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        .frame(width: geometry.outerRadius * 2, height: geometry.outerRadius * 2)
                        .position(geometry.center)
                } else {
                    ring(geometry)
                }
            }
            .frame(width: geometry.size, height: geometry.size)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    highlighted = geometry.index(at: location).map { actions[$0].id }
                case .ended:
                    highlighted = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                if let index = geometry.index(at: location) { onSelect(actions[index].id) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("ring.preview.accessibility", actions.map(\.title).joined(separator: ", ")))
    }

    @ViewBuilder private func ring(_ geometry: RingPreviewGeometry) -> some View {
        let diameter = geometry.outerRadius * 2
        ZStack {
            ringSurface
                .mask {
                    Circle().frame(width: diameter, height: diameter)
                        .overlay(Circle().frame(width: geometry.innerRadius * 2).blendMode(.destinationOut))
                        .compositingGroup()
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                .position(geometry.center)
            ForEach(actions.indices, id: \.self) { index in
                if actions[index].id == highlighted {
                    RingSectorShape(geometry: geometry, index: index)
                        .fill(RadialGradient(colors: [Color(red: 0.93, green: 0.57, blue: 0.34).opacity(0.65),
                                                      Color(red: 0.72, green: 0.43, blue: 0.34).opacity(0.18)],
                                             center: UnitPoint(x: 0.5, y: 0.5), startRadius: 0,
                                             endRadius: geometry.outerRadius))
                }
                separator(geometry, index: index)
            }
            Circle().strokeBorder(.white.opacity(style == .liquidGlass ? 0.45 : 0.14), lineWidth: 1)
                .frame(width: diameter, height: diameter).position(geometry.center)
            Circle().fill(Color(white: style == .classic ? 0.11 : 0.15).opacity(0.92))
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .frame(width: geometry.centerRadius * 2, height: geometry.centerRadius * 2)
                .position(geometry.center)
            VStack(spacing: 2) {
                Text(centerTitle.isEmpty ? RingConfiguration.defaultCenterTitle : centerTitle)
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(L("ring.preview.count", actions.count)).font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55)).tracking(0.6)
            }
            .frame(width: geometry.centerRadius * 1.8)
            .position(geometry.center)
            ForEach(actions.indices, id: \.self) { index in
                slice(geometry, index: index)
            }
        }
    }

    @ViewBuilder private var ringSurface: some View {
        switch style {
        case .classic:
            LinearGradient(colors: [Color(white: 0.08), Color(white: 0.115)], startPoint: .top, endPoint: .bottom)
        case .frosted:
            Rectangle().fill(.regularMaterial).overlay(Color(white: 0.1).opacity(0.55))
        case .liquidGlass:
            Rectangle().fill(.ultraThinMaterial).overlay(Color.white.opacity(0.05))
        }
    }

    private func separator(_ geometry: RingPreviewGeometry, index: Int) -> some View {
        let angle = geometry.angle(of: index) + .pi / CGFloat(geometry.count)
        return Path { path in
            path.move(to: geometry.point(at: geometry.innerRadius, angle: angle))
            path.addLine(to: geometry.point(at: geometry.outerRadius, angle: angle))
        }
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }

    @ViewBuilder private func slice(_ geometry: RingPreviewGeometry, index: Int) -> some View {
        let action = actions[index]
        let isOn = action.id == highlighted
        let angle = geometry.angle(of: index)
        RingActionIcon(action: action, size: geometry.size * 0.065)
            .foregroundStyle(isOn ? Self.warm : .white.opacity(0.88))
            .scaleEffect(isOn ? 1.12 : 1)
            .position(geometry.point(at: (geometry.innerRadius + geometry.outerRadius) / 2, angle: angle))
        Text(RingSettingsPresentation.sliceLabel(action.title))
            .font(.system(size: 9, weight: isOn ? .semibold : .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(isOn ? Self.warm : .white.opacity(0.75))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? Color(red: 0.23, green: 0.17, blue: 0.09) : Color(white: 0.1).opacity(0.85)))
            .fixedSize()
            .position(geometry.point(at: geometry.labelRadius, angle: angle))
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
