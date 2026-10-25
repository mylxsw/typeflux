import AppKit
import SwiftUI

/// What the centre disc shows: the global title and count, or an app's icon and name. With two
/// pages (an app and the global actions) page dots tell which one is shown.
struct RingStudioCenter: Equatable {
    var title: String
    var appBundleIdentifier: String?
    var pageCount = 1
    var pageIndex = 0
}

/// The ring drawn in the studio: surface, slices, labels, numbers and the centre disc.
/// Drawing only; the canvas around it handles the pointer and keys.
struct RingStudioRing: View {
    let slots: [RingStudioSlot]
    /// The slice drawn as selected, or under the pointer while trying.
    let highlighted: Int?
    let isTrying: Bool
    let style: RingStyle
    let center: RingStudioCenter
    let actionCount: Int
    let issues: Set<UUID>
    let size: CGFloat
    /// The pointer is over a centre that can be clicked.
    var centerHighlighted = false

    private var geometry: RingPreviewGeometry {
        RingPreviewGeometry(size: size, count: slots.count)
    }

    var body: some View {
        let diameter = geometry.outerRadius * 2
        ZStack {
            surface
                .mask {
                    Circle().frame(width: diameter, height: diameter)
                        .overlay(Circle().frame(width: geometry.innerRadius * 2).blendMode(.destinationOut))
                        .compositingGroup()
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                .position(geometry.center)
            ForEach(slots.indices, id: \.self) { index in
                sectorFill(index: index, highlighted: highlighted == index)
            }
            if slots.count > 1 {
                ForEach(slots.indices, id: \.self) { index in separator(index: index) }
            }
            Circle().strokeBorder(.white.opacity(style == .liquidGlass ? 0.45 : 0.18), lineWidth: 1)
                .frame(width: diameter, height: diameter).position(geometry.center)
            centerDisc
            ForEach(slots.indices, id: \.self) { index in
                slice(index: index, highlighted: highlighted == index)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: slots.map(\.id))
    }

    @ViewBuilder private var surface: some View {
        switch style {
        case .classic:
            LinearGradient(colors: [Color(white: 0.08), Color(white: 0.115)], startPoint: .top, endPoint: .bottom)
        case .frosted:
            Rectangle().fill(.regularMaterial).overlay(Color(white: 0.1).opacity(0.55))
        case .liquidGlass:
            Rectangle().fill(.ultraThinMaterial).overlay(Color.white.opacity(0.05))
        }
    }

    @ViewBuilder private func sectorFill(index: Int, highlighted: Bool) -> some View {
        let shape = RingSectorShape(geometry: geometry, index: index)
        switch slots[index].role {
        case .placeholder:
            shape.fill(RingStudioCanvas.selectionBlue.opacity(0.2))
                .overlay(shape.stroke(RingStudioCanvas.selectionBlue, style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
        case .preview:
            shape.fill(RingStudioCanvas.selectionBlue.opacity(0.3))
                .overlay(shape.stroke(RingStudioCanvas.selectionBlue, lineWidth: 1.4))
        case .action where highlighted && isTrying:
            shape.fill(RadialGradient(colors: [Color(red: 0.93, green: 0.57, blue: 0.34).opacity(0.65),
                                               Color(red: 0.72, green: 0.43, blue: 0.34).opacity(0.18)],
                                      center: .center, startRadius: 0, endRadius: geometry.outerRadius))
        case .action where highlighted:
            shape.fill(Color.white.opacity(0.13)).overlay(shape.stroke(RingStudioCanvas.selectionBlue, lineWidth: 1.6))
        case .action:
            EmptyView()
        }
    }

    private func separator(index: Int) -> some View {
        let angle = geometry.angle(of: index) + .pi / CGFloat(geometry.count)
        return Path { path in
            path.move(to: geometry.point(at: geometry.innerRadius, angle: angle))
            path.addLine(to: geometry.point(at: geometry.outerRadius, angle: angle))
        }
        .stroke(.white.opacity(style == .classic ? 0.07 : 0.12), lineWidth: 1)
    }

    private var centerDisc: some View {
        ZStack {
            Circle().fill(Color(white: style == .classic ? 0.11 : 0.15).opacity(0.92))
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .frame(width: geometry.centerRadius * 2, height: geometry.centerRadius * 2)
            if centerHighlighted {
                Circle().strokeBorder(RingStudioCanvas.selectionBlue.opacity(0.9), lineWidth: 2)
                    .frame(width: geometry.centerRadius * 2 + 2, height: geometry.centerRadius * 2 + 2)
            }
            VStack(spacing: 2) {
                if let bundleIdentifier = center.appBundleIdentifier {
                    Image(nsImage: RingAppIcon.image(bundleIdentifier: bundleIdentifier))
                        .resizable().frame(width: 20, height: 20)
                    Text(center.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(center.title.isEmpty ? RingConfiguration.defaultCenterTitle : center.title)
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(L("ring.preview.count", actionCount)).font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55)).tracking(0.6)
                }
                if center.pageCount > 1 {
                    pageDots.padding(.top, 2)
                }
            }
            .frame(width: geometry.centerRadius * 1.7)
        }
        .position(geometry.center)
    }

    /// The shown page is a short bar, the other a dot, as on the real ring.
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< center.pageCount, id: \.self) { page in
                Capsule().fill(.white.opacity(page == center.pageIndex ? 0.95 : 0.35))
                    .frame(width: page == center.pageIndex ? 10 : 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func slice(index: Int, highlighted: Bool) -> some View {
        let slot = slots[index]
        let angle = geometry.angle(of: index)
        let broken = issues.contains(slot.id)
        let iconColor: Color = broken ? .white.opacity(0.35)
            : highlighted && isTrying ? RingStudioCanvas.warm
            : slot.role == .placeholder ? Color(red: 0.61, green: 0.82, blue: 1) : .white.opacity(0.92)
        RingActionIcon(action: slot.action, size: geometry.size * (highlighted ? 0.068 : 0.06))
            .foregroundStyle(iconColor)
            .opacity(broken ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if broken {
                    Circle().fill(RingStudioCanvas.warm).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1)).offset(x: 6, y: -4)
                }
            }
            .position(geometry.point(at: (geometry.innerRadius + geometry.outerRadius) / 2 + 2, angle: angle))
        if slot.role != .placeholder {
            label(slot, highlighted: highlighted, angle: angle)
        }
    }

    private func label(_ slot: RingStudioSlot, highlighted: Bool, angle: CGFloat) -> some View {
        let isNew = slot.role != .action
        return Text(RingSettingsPresentation.sliceLabel(slot.action.title))
            .font(.system(size: 9.5, weight: highlighted || isNew ? .semibold : .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(isNew ? Color(red: 0.84, green: 0.93, blue: 1)
                : highlighted && isTrying ? RingStudioCanvas.warm : highlighted ? .white : .white.opacity(0.75))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(labelFill(slot, highlighted)))
            .fixedSize()
            .position(geometry.point(at: geometry.labelRadius, angle: angle))
    }

    private func labelFill(_ slot: RingStudioSlot, _ highlighted: Bool) -> Color {
        if slot.role != .action {
            return Color(red: 0.09, green: 0.35, blue: 0.67).opacity(0.92)
        }
        if highlighted, isTrying {
            return Color(red: 0.23, green: 0.17, blue: 0.09).opacity(0.95)
        }
        if highlighted {
            return Color(red: 0.08, green: 0.24, blue: 0.43).opacity(0.92)
        }
        return Color(white: 0.1).opacity(0.8)
    }
}
