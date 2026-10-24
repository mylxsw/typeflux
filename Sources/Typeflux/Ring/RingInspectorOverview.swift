import SwiftUI

/// The top of an inspector state: an optional back link, a title and a close button.
struct RingInspectorHeader: View {
    var backTitle: String?
    var onBack: (() -> Void)?
    let title: String
    var closeTitle: String?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let backTitle, let onBack {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(backTitle).font(.system(size: 12.5))
                    }
                    .foregroundStyle(TFColors.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ring.inspector.back")
            }
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                TFButton(title: closeTitle ?? L("common.cancel"), systemImage: "xmark", kind: .plain, size: .small,
                         iconOnly: true, action: onClose)
                    .accessibilityIdentifier("ring.inspector.close")
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 10)
        .frame(minHeight: 48)
    }
}

/// The inspector with nothing selected: the slices in ring order, which can be dragged to reorder.
struct RingInspectorOverview: View {
    let actions: [RingAction]
    let issues: [UUID: String]
    let detail: (RingAction) -> String
    var onSelect: (UUID) -> Void = { _ in }
    var onMove: (UUID, Int) -> Void = { _, _ in }
    var onAdd: () -> Void = {}

    private var isFull: Bool {
        actions.count >= RingConfiguration.maxActions
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        RingOverviewRow(index: index, action: action, detail: detail(action),
                                        issue: issues[action.id]) { onSelect(action.id) }
                            .draggable(action.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                                onMove(id, index)
                                return true
                            }
                    }
                    footer.padding(.top, 4)
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
        }
    }

    /// A full ring has no add row; the canvas shows 8 / 8.
    @ViewBuilder private var footer: some View {
        if !isFull {
            Button(action: onAdd) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5])))
                        .padding(.leading, 28)
                    Text(L("ring.actions.add")).font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 8)
                }
                .foregroundStyle(TFColors.accent)
                .padding(.horizontal, 8).frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(RingRowButtonStyle())
            .accessibilityIdentifier("ring.actions.add")
        }
    }
}

/// A slice in the overview list.
struct RingOverviewRow: View {
    let index: Int
    let action: RingAction
    /// What the slice runs; read by VoiceOver, the row itself shows only the name.
    let detail: String
    let issue: String?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(.system(size: 11)).monospacedDigit().foregroundStyle(TFColors.textTertiary)
                    .frame(width: 18)
                RingIconTile(action: action, size: 26)
                Text(action.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TFColors.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                if let issue {
                    Circle().fill(TFColors.warning).frame(width: 7, height: 7).help(issue).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8).frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RingRowButtonStyle())
        .accessibilityLabel(action.title)
        .accessibilityHint(issue ?? detail)
        .accessibilityIdentifier("ring.overview.row.\(index + 1)")
    }
}

/// A slice's icon on a small tile, in the colours of the inspector.
struct RingIconTile: View {
    let action: RingAction
    var size: CGFloat = 28
    var dark = false

    var body: some View {
        RingActionIcon(action: action, size: size * 0.5)
            .foregroundStyle(dark ? Color.white : TFColors.textSecondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(dark ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.09)],
                                                          startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(TFColors.control)))
            .accessibilityHidden(true)
    }
}

/// A highlighted row background that follows the pointer.
struct RingRowButtonStyle: ButtonStyle {
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isHighlighted: isHighlighted)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let isHighlighted: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHighlighted ? TFColors.selection
                        : configuration.isPressed ? TFColors.pressedOverlay
                        : hovering ? TFColors.hoverOverlay : Color.clear))
                .onHover { hovering = $0 }
        }
    }
}

/// One line with an icon and an action, for a slice that cannot run.
struct RingInspectorBanner<Accessory: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(TFColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint.opacity(0.3), lineWidth: TFMetrics.borderWidth))
    }
}
