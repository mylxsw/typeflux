import SwiftUI

/// A 28pt rounded tile with an SF Symbol or the first letter of a name.
struct TFIconTile: View {
    var systemImage: String?
    var letter: String = ""
    var tint: Color = TFColors.accent
    var size: CGFloat = TFMetrics.iconTileSize

    static func initial(of text: String) -> String {
        text.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? ""
    }

    var body: some View {
        let corner = size * TFMetrics.iconTileCornerRadius / TFMetrics.iconTileSize
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: size * 0.54, weight: .semibold))
                } else {
                    Text(verbatim: Self.initial(of: letter)).font(.system(size: size * 0.43, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

/// A 16pt capsule label: "Built-in", "Default", or a monospaced trigger word.
struct TFTag: View {
    let text: String
    var monospaced = false
    var tint: Color?
    var query = ""

    var body: some View {
        Text(TFSearchMatcher.highlighted(text, query: query))
            .font(.system(size: monospaced ? 10 : 10.5, weight: .medium, design: monospaced ? .monospaced : .default))
            .foregroundStyle(tint ?? TFColors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: TFMetrics.tagHeight)
            .background(Capsule(style: .circular).fill(tint?.opacity(0.14) ?? TFColors.hoverOverlay))
            .overlay {
                if tint == nil { Capsule(style: .circular).strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth) }
            }
            .fixedSize()
    }
}

/// A 6pt status dot.
struct TFStatusDot: View {
    enum Level: Equatable { case success, warning, danger, neutral }

    var level: Level

    var color: Color {
        switch level {
        case .success: TFColors.success
        case .warning: TFColors.warning
        case .danger: TFColors.danger
        case .neutral: TFColors.textTertiary
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

/// A dot and a short state, e.g. "● Configured".
struct TFStatusLabel: View {
    let text: String
    var level: TFStatusDot.Level = .neutral
    /// Colors the text too, for live states like "Running".
    var tintsText = false

    var body: some View {
        HStack(spacing: 5) {
            TFStatusDot(level: level)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tintsText ? TFStatusDot(level: level).color : TFColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The caption above a group: "Configured · 4 items", with up to two small actions on the right.
struct TFSectionHeader<Actions: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(TFColors.textSecondary)
            if let count {
                Text(L("settings.list.itemCount", count)).font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions }.tfControlSize(.small)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: TFControlSize.small.height)
        .accessibilityElement(children: .contain)
    }
}

extension TFSectionHeader where Actions == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A rounded card (12pt) for grouped rows and form rows. Separate rows with `TFDivider`.
struct TFCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
        VStack(spacing: 0) { content }
            .background(TFColors.card, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
    }
}

/// A hairline between rows, starting at the row title so it lines up with the text.
struct TFDivider: View {
    /// Rows with a 28pt icon tile: 50pt. Rows without one and form rows: 12–14pt.
    var inset: CGFloat = TFListGroupInset.withIcon

    /// Between `TFFormRow`s.
    static var form: TFDivider { TFDivider(inset: TFListGroupInset.form) }

    var body: some View {
        Rectangle().fill(TFColors.border).frame(height: TFMetrics.borderWidth).padding(.leading, inset)
    }
}

enum TFListGroupInset {
    static let withIcon = TFMetrics.rowHorizontalPadding + TFMetrics.iconTileSize + 10
    static let plain = TFMetrics.rowHorizontalPadding
    static let form: CGFloat = 14
}

/// A card of rows built from data, with hairlines between rows (macOS System Settings style).
struct TFListGroup<Data: RandomAccessCollection, ID: Hashable, Row: View>: View {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    var separatorInset: CGFloat = TFListGroupInset.withIcon
    @ViewBuilder let row: (Data.Element) -> Row

    init(_ data: Data, id: KeyPath<Data.Element, ID>, separatorInset: CGFloat = TFListGroupInset.withIcon,
         @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.id = id
        self.separatorInset = separatorInset
        self.row = row
    }

    var body: some View {
        TFCard {
            let firstID = data.first?[keyPath: id]
            ForEach(data, id: id) { element in
                if element[keyPath: id] != firstID { TFDivider(inset: separatorInset) }
                row(element)
            }
        }
    }
}

extension TFListGroup where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data, separatorInset: CGFloat = TFListGroupInset.withIcon,
         @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.init(data, id: \.id, separatorInset: separatorInset, row: row)
    }
}

/// Spec §8: a list row. Icon, title with tags, an optional one-line subtitle and up to two
/// trailing accessories (status, switch, chevron, small button or "⋯" menu).
struct TFListRow<Leading: View, Accessory: View>: View {
    enum Density { case regular, compact }

    let title: String
    var subtitle: String?
    var tags: [String] = []
    var monospacedTags = false
    var query = ""
    var density: Density = .regular
    var isSelected = false
    var action: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var accessory: Accessory
    @State private var hovering = false

    static func height(hasSubtitle: Bool, density: Density) -> CGFloat {
        if density == .compact { return TFMetrics.compactRowHeight }
        return hasSubtitle ? TFMetrics.rowHeight : TFMetrics.singleLineRowHeight
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    TFHighlightedText(text: title, query: query)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TFColors.textPrimary)
                        .lineLimit(1)
                    ForEach(tags, id: \.self) { TFTag(text: $0, monospaced: monospacedTags, query: query) }
                }
                if let subtitle {
                    TFHighlightedText(text: subtitle, query: query)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TFColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) { accessory }
                .foregroundStyle(TFColors.textTertiary)
                .tfControlSize(.small)
        }
        .padding(.horizontal, TFMetrics.rowHorizontalPadding)
        .padding(.vertical, density == .compact ? 3 : 6)
        .frame(minHeight: Self.height(hasSubtitle: subtitle != nil, density: density))
        .background(isSelected ? TFColors.selection : (hovering ? TFColors.hoverOverlay : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

extension TFListRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, tags: [String] = [], monospacedTags: Bool = false, query: String = "",
         density: Density = .regular, isSelected: Bool = false, action: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, subtitle: subtitle, tags: tags, monospacedTags: monospacedTags, query: query,
                  density: density, isSelected: isSelected, action: action, leading: { EmptyView() },
                  accessory: accessory)
    }
}

/// The disclosure chevron for rows that open a detail page.
struct TFChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TFColors.textTertiary).accessibilityHidden(true)
    }
}

/// An empty list: icon, title, explanation and up to two actions.
struct TFEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TFColors.hoverOverlay)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: systemImage).font(.system(size: 20)).foregroundStyle(TFColors.textTertiary)
                }
                .padding(.bottom, 4)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
            if let message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            HStack(spacing: 8) { actions }.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .contain)
    }
}

/// Search found nothing: offers "Clear Search", and "Search All" while a filter is active.
struct TFSearchEmptyState: View {
    let query: String
    var onClear: () -> Void
    /// Non-nil while a filter narrows the results.
    var onSearchAll: (() -> Void)?

    var body: some View {
        TFEmptyState(systemImage: "magnifyingglass", title: L("component.search.noResults", query),
                     message: L(onSearchAll == nil ? "component.search.tryAnother" : "component.search.tryAll")) {
            TFButton(title: L("component.search.clear"), action: onClear)
            if let onSearchAll {
                TFButton(title: L("component.search.searchAll"), action: onSearchAll)
            }
        }
    }
}
