import SwiftUI

/// The header at the top of a pane: an accent icon tile, the title, an optional line of
/// explanation, and the pane's main actions on the right (wrapping below when narrow).
struct TFPaneHeader<Accessory: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var badge: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                HStack(spacing: TFMetrics.toolbarSpacing) { accessory }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                heading
                HStack(spacing: TFMetrics.toolbarSpacing) { Spacer(minLength: 0); accessory }
            }
        }
        .tfControlSize(.regular)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 14) {
            TFIconTile(systemImage: systemImage, tint: TFColors.accent, size: 40, style: .soft)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    if let badge { TFTag(text: badge, tint: TFColors.accent) }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension TFPaneHeader where Accessory == EmptyView {
    init(systemImage: String, title: String, subtitle: String? = nil, badge: String? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, badge: badge) { EmptyView() }
    }
}

/// An accent row that adds to (or acts on) the card above it, e.g. "Add Folder".
struct TFActionRow: View {
    let systemImage: String
    let title: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let tint = destructive ? TFColors.danger : TFColors.accent
        Button(action: action) {
            HStack(spacing: 12) {
                TFIconTile(systemImage: systemImage, tint: tint, style: .soft)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: TFMetrics.formRowMinHeight)
            .background(hovering ? TFColors.hoverOverlay : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A muted line inside a card that has nothing to list yet.
struct TFCardNote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(TFColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 16)
    }
}

/// A small label above a figure, e.g. "Indexed · 12,408".
struct TFMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Confirms a destructive action in place, without a modal dialog.
struct TFInlineConfirmation: View {
    let title: String
    let message: String
    let confirmTitle: String
    var cancelTitle: String = L("common.cancel")
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
            Text(message).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFButton(title: confirmTitle, kind: .primary, destructive: true, size: .small, action: onConfirm)
                TFButton(title: cancelTitle, size: .small, action: onCancel)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColors.control,
                    in: RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous))
    }
}

/// Lays children out left to right, wrapping onto new lines when the width runs out.
struct TFFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = Self.rows(width: width, sizes: Self.sizes(subviews, width: width), spacing: spacing)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let sizes = Self.sizes(subviews, width: bounds.width)
        var top = bounds.minY
        for row in Self.rows(width: bounds.width, sizes: sizes, spacing: spacing) {
            var left = bounds.minX
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: left, y: top + (row.height - sizes[index].height) / 2),
                                      proposal: ProposedViewSize(sizes[index]))
                left += sizes[index].width + spacing
            }
            top += row.height + spacing
        }
    }

    struct Row: Equatable {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Each item's ideal size, narrowed to the line so a long item truncates instead of overflowing.
    private static func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return ideal.width <= width ? ideal : subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }

    /// Greedy line breaking; an item wider than the line gets a line of its own.
    static func rows(width: CGFloat, sizes: [CGSize], spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, size) in sizes.enumerated() {
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, next > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A list of short values (file extensions, folder names) as removable tokens, with a field
/// to add more. `normalize` cleans the typed text and returns nil when it cannot be added.
struct TFTokenInput: View {
    let values: [String]
    let placeholder: String
    var addTitle: String = L("component.add")
    let normalize: (String) -> String?
    let onChange: ([String]) -> Void
    @State private var text = ""

    /// The values after adding `text`, or nil when it is empty, invalid or already present.
    static func adding(_ text: String, to values: [String], normalize: (String) -> String?) -> [String]? {
        guard let value = normalize(text), !values.contains(value) else { return nil }
        return values + [value]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !values.isEmpty {
                TFFlowLayout(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        token(value)
                    }
                }
            }
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(TFTextFieldStyle(monospaced: true))
                    .frame(maxWidth: 240)
                    .onSubmit(add)
                TFButton(title: addTitle, systemImage: "plus", action: add)
                    .disabled(normalize(text) == nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func token(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(TFColors.textPrimary)
            Button { onChange(values.filter { $0 != value }) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(TFColors.textTertiary)
            .accessibilityLabel(L("component.remove") + " " + value)
        }
        .padding(.leading, 9).padding(.trailing, 7)
        .frame(height: TFControlSize.small.height)
        .background(Capsule(style: .circular).fill(TFColors.control))
        .overlay(Capsule(style: .circular).strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
    }

    private func add() {
        if let next = Self.adding(text, to: values, normalize: normalize) {
            onChange(next)
        }
        text = ""
    }
}

/// A checkbox for lists where several items can be chosen (switches are for settings).
struct TFCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
    }
}

/// A thin horizontal bar showing a share of a total, e.g. one app's part of the storage.
struct TFMeter: View {
    let value: Double
    let total: Double
    var width: CGFloat = 120

    /// The filled fraction, clamped to 0…1; an empty total shows nothing.
    static func fraction(_ value: Double, of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .circular).fill(TFColors.control)
            Capsule(style: .circular).fill(TFColors.accent)
                .frame(width: width * Self.fraction(value, of: total))
        }
        .frame(width: width, height: 6)
        .accessibilityElement()
        .accessibilityValue("\(Int((Self.fraction(value, of: total) * 100).rounded()))%")
    }
}

/// A selectable row in a source list (a list column beside its detail), e.g. a persona.
/// `dimmedPrefix` greys a leading label such as "Candidate:"; `showsChangeDot` marks unsaved edits.
struct TFSourceRow: View {
    let title: String
    var dimmedPrefix: String?
    var query = ""
    let isSelected: Bool
    var showsChangeDot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label.lineLimit(1)
                if showsChangeDot { TFStatusDot(level: .warning) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: TFMetrics.paneRowHeight + 2)
            .background(isSelected ? TFColors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous))
        }
        .buttonStyle(TFRowHoverStyle(selected: isSelected))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: Text {
        let tint = isSelected ? TFColors.accent : TFColors.textPrimary
        if let dimmedPrefix, title.hasPrefix(dimmedPrefix) {
            return Text(dimmedPrefix).foregroundColor(TFColors.textSecondary)
                + Text(TFSearchMatcher.highlighted(String(title.dropFirst(dimmedPrefix.count)), query: query))
                .foregroundColor(tint)
        }
        return Text(TFSearchMatcher.highlighted(title, query: query)).foregroundColor(tint)
    }
}

/// A neutral icon tile holding a logo or other custom artwork (provider and app logos).
struct TFLogoTile<Content: View>: View {
    var size: CGFloat = TFMetrics.iconTileSize
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(TFColors.control, in: RoundedRectangle(
                cornerRadius: size * TFMetrics.iconTileCornerRadius / TFMetrics.iconTileSize, style: .continuous))
            .accessibilityHidden(true)
    }
}
