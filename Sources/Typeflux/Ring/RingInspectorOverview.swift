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
        GeometryReader { geometry in
            // Reserve room for grid padding, three gaps, and the instruction footer.
            let tileHeight = max(96, (geometry.size.height - 90) / 4)
            VStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            RingOverviewRow(index: index, action: action, detail: detail(action),
                                            issue: issues[action.id], height: tileHeight) { onSelect(action.id) }
                                .draggable(action.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let id = items.first.flatMap(UUID.init(uuidString:)),
                                          actions.contains(where: { $0.id == id }) else { return false }
                                    onMove(id, index)
                                    return true
                                }
                        }
                        if !isFull {
                            Button(action: onAdd) {
                                VStack(spacing: 10) {
                                    Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                                    Text(L("ring.actions.add")).font(.system(size: 12.5, weight: .medium))
                                }
                                .foregroundStyle(TFColors.accent)
                                .frame(maxWidth: .infinity).frame(height: tileHeight)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(RingOverviewTileStyle())
                            .accessibilityIdentifier("ring.actions.add")
                        }
                    }
                    .padding(12)
                }
                Text(L("ring.actions.gridHint"))
                    .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                    .padding(.bottom, 12).padding(.top, 4)
            }
        }
    }
}

/// A draggable action tile, ordered left to right and then top to bottom.
struct RingOverviewRow: View {
    let index: Int
    let action: RingAction
    let detail: String
    let issue: String?
    var height: CGFloat = 110
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                RingIconTile(action: action, size: 36)
                Text(action.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TFColors.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 34, alignment: .top)
            }
            .padding(.horizontal, 12).padding(.top, 18)
            .frame(maxWidth: .infinity).frame(height: height)
            .overlay(alignment: .topLeading) {
                Text("\(index + 1)").font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(TFColors.textSecondary).padding(10)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: issue == nil ? "line.3.horizontal" : "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(issue == nil ? TFColors.textTertiary : TFColors.warning)
                    .padding(10).accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RingOverviewTileStyle())
        .help(issue ?? detail)
        .accessibilityLabel(action.title)
        .accessibilityHint(issue ?? detail)
        .accessibilityIdentifier("ring.overview.row.\(index + 1)")
    }
}

/// A restrained tile surface with a blue hover and press affordance.
struct RingOverviewTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? TFColors.selection
                        : hovering ? TFColors.accent.opacity(0.1) : TFColors.control.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? TFColors.accent : TFColors.border, lineWidth: 1))
                .onHover { hovering = $0 }
        }
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
