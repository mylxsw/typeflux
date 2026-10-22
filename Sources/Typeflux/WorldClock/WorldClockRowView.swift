import SwiftUI

/// One city: day/night icon, name and difference, local time, and its 24-hour bar.
/// The chosen row adds its zone, the next daylight saving change and its actions.
struct WorldClockRowView: View {
    struct Action: Identifiable {
        var key: AskCommandKey
        var title: String
        var symbol: String
        var shortcut: String
        var primary = false
        var id: String {
            title
        }
    }

    static let barWidth: CGFloat = 260
    static let rowHeight: CGFloat = 52

    var row: WorldClockRow
    var selected: Bool
    var dimmed: Bool
    var source: Bool
    var added: Bool
    /// Where the shown moment falls on the bar, 0...1.
    var cursor: Double
    var moved: Bool
    var band: (start: Double, width: Double)?
    var actions: [Action]
    var onSelect: () -> Void
    var onBar: (Double) -> Void
    var onAction: (AskCommandKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                periodIcon
                VStack(alignment: .leading, spacing: 2) {
                    nameLine
                    Text(row.subtitle).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.time).font(.system(size: 21, weight: .semibold).monospacedDigit()).lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(row.day).font(.system(size: 10.5, weight: row.differentDay ? .semibold : .regular))
                        .foregroundStyle(row.differentDay ? Color.orange : StudioTheme.textTertiary).lineLimit(1)
                }.frame(width: 96, alignment: .trailing)
                bar
            }
            .frame(height: Self.rowHeight)
            .opacity(dimmed ? 0.55 : 1)
            if selected {
                detail.padding(.leading, 38).padding(.bottom, 9)
            }
        }
        .padding(.horizontal, 10)
        .background(selected ? AskTheme.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? AskTheme.accent.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name) \(row.time) \(row.day)")
        .accessibilityIdentifier("worldclock.row." + row.city.id)
    }

    private var periodIcon: some View {
        let symbol = row.period == .day ? "sun.max.fill" : row.period == .twilight ? "sun.horizon.fill" : "moon.fill"
        let tint: Color = row.period == .night ? .indigo : .orange
        return Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            .frame(width: 28, height: 28).background(StudioTheme.textPrimary.opacity(0.07), in: Circle())
    }

    private var nameLine: some View {
        HStack(spacing: 6) {
            Text(row.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            if let label = row.label {
                Text(label).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            if row.isLocal { tag(L("worldclock.local"), AskTheme.accent) }
            if row.isDaylightSaving { tag(L("worldclock.dst"), .orange) }
            if source { tag(L("worldclock.source"), AskTheme.accent) }
            if added { tag(L("worldclock.added.tag"), .green) }
        }
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 5).frame(height: 15)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    private var bar: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(row.slots.enumerated()), id: \.offset) { _, slot in
                    Rectangle().fill(Self.color(slot))
                }
            }
            .frame(width: Self.barWidth, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            ForEach(Array(row.markers.enumerated()), id: \.offset) { _, marker in
                markerView(marker)
            }
            if let band {
                Rectangle().fill(Color.green.opacity(0.2))
                    .overlay(Rectangle().stroke(Color.green, lineWidth: 1))
                    .frame(width: Self.barWidth * band.width, height: Self.rowHeight)
                    .offset(x: Self.barWidth * band.start)
            } else if (0 ... 1).contains(cursor) {
                Rectangle().fill(moved ? Color.orange : AskTheme.accent)
                    .frame(width: 2, height: Self.rowHeight).offset(x: Self.barWidth * cursor - 1)
            }
        }
        .frame(width: Self.barWidth, height: Self.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { onBar($0.location.x / Self.barWidth) })
        .accessibilityHidden(true)
    }

    private func markerView(_ marker: WorldClockRow.Marker) -> some View {
        let position = Self.barWidth * marker.fraction
        let atEnd = marker.fraction > 0.88
        return ZStack(alignment: .leading) {
            if marker.midnight {
                Rectangle().fill(StudioTheme.textTertiary).frame(width: 1, height: 24).offset(x: position)
            }
            Text(marker.text)
                .font(.system(size: 9.5, weight: marker.midnight ? .bold : .regular).monospacedDigit())
                .foregroundStyle(marker.midnight ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .fixedSize()
                .frame(width: 40, alignment: marker.midnight ? (atEnd ? .trailing : .leading) : .center)
                .offset(x: marker.midnight ? (atEnd ? position - 43 : position + 3) : position - 20)
        }
    }

    private var detail: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.detail).foregroundStyle(StudioTheme.textSecondary)
                if let transition = row.transition {
                    Text(transition).foregroundStyle(row.transitionSoon ? Color.orange : StudioTheme.textTertiary)
                }
            }.font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ForEach(actions) { action in
                Button { onAction(action.key) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: action.symbol).font(.system(size: 10))
                        Text(action.title)
                        Text(action.shortcut).foregroundStyle(action.primary ? Color.white.opacity(0.75)
                            : StudioTheme.textTertiary)
                    }
                    .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 24)
                    .foregroundStyle(action.primary ? Color.white : StudioTheme.textPrimary)
                    .background(action.primary ? AskTheme.accent : AskTheme.hoverFill,
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(action.primary ? Color.clear : AskTheme.separator))
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityIdentifier("worldclock.action." + action.symbol)
            }
        }
    }

    static func color(_ slot: WorldClockRow.Slot) -> Color {
        switch slot {
        case .work: AskTheme.accent.opacity(0.42)
        case .awake: AskTheme.accent.opacity(0.17)
        case .night: StudioTheme.textPrimary.opacity(0.05)
        case .rest: StudioTheme.textPrimary.opacity(0.12)
        }
    }
}
