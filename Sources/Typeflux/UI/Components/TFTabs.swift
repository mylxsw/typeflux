import SwiftUI

/// One option of a tab bar, segmented control or filter.
struct TFOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var systemImage: String?
    var count: Int?
    /// Tooltip for icon-only segments.
    var help: String?

    var id: Value { value }

    init(_ value: Value, _ title: String, systemImage: String? = nil, count: Int? = nil, help: String? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.help = help
    }

    /// An icon-only option; `help` is required so the segment still has a name.
    static func icon(_ value: Value, systemImage: String, help: String) -> TFOption {
        TFOption(value, "", systemImage: systemImage, help: help)
    }
}

/// Cyclic keyboard movement shared by tab bars and segmented controls.
enum TFSelectionStep {
    static func value<Value: Hashable>(after current: Value, in values: [Value], forward: Bool) -> Value? {
        guard !values.isEmpty else { return nil }
        guard let index = values.firstIndex(of: current) else { return values.first }
        let next = (index + (forward ? 1 : -1) + values.count) % values.count
        return values[next]
    }
}

/// Level 1 (spec §4.1): underlined tabs that switch whole pages. 2–6 tabs under the page title.
struct TFTabBar<Value: Hashable>: View {
    let options: [TFOption<Value>]
    @Binding var selection: Value
    var identifier: ((Value) -> String)?
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: TFMetrics.tabSpacing) {
            ForEach(options) { option in
                tab(option)
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
        .frame(height: TFMetrics.tabHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TFColors.border).frame(height: TFMetrics.borderWidth)
        }
        .focusable()
        .onMoveCommand { direction in
            guard direction == .left || direction == .right,
                  let next = TFSelectionStep.value(after: selection, in: options.map(\.value),
                                                   forward: direction == .right)
            else { return }
            select(next)
        }
        .accessibilityElement(children: .contain)
    }

    private func tab(_ option: TFOption<Value>) -> some View {
        let selected = option.value == selection
        return Button { select(option.value) } label: {
            HStack(spacing: 4) {
                Text(option.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? TFColors.textPrimary : TFColors.textSecondary)
                if let count = option.count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(TFColors.textTertiary)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule(style: .circular).fill(TFColors.accent).frame(height: TFMetrics.tabIndicatorHeight)
                        .matchedGeometryEffect(id: "indicator", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TFHoverTextStyle())
        .accessibilityLabel(option.count.map { "\(option.title), \($0)" } ?? option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier?(option.value) ?? option.title)
    }

    /// Only the indicator animates (see `.animation` on the bar): animating the binding itself
    /// would animate the page swap, keeping the outgoing page alive and reusing it on a quick return.
    private func select(_ value: Value) {
        selection = value
    }
}

/// Brightens unselected tab titles on hover without any fill.
private struct TFHoverTextStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering ? 0.08 : 0)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

/// Level 2 (spec §4.2): a capsule segmented control for views or filters of the same content.
/// Up to 4 options in toolbars, up to 5 in forms. Counts update with the search query.
struct TFSegmentedControl<Value: Hashable>: View {
    let options: [TFOption<Value>]
    @Binding var selection: Value
    /// Nil follows the environment; `.large` is not offered and falls back to `.regular`.
    var size: TFControlSize?
    /// Equal-width segments filling the width, for form rows.
    var fillsWidth = false
    var identifier: ((Value) -> String)?
    @Environment(\.tfControlSize) private var environmentSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    private var resolvedSize: TFControlSize {
        let size = size ?? environmentSize
        return size == .large ? .regular : size
    }

    var body: some View {
        let size = resolvedSize
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option, size: size)
            }
        }
        // Animate the thumb only, not the content the selection drives.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
        .padding(TFMetrics.segmentInset)
        .frame(height: size.height)
        .background(Capsule(style: .circular).fill(TFColors.control))
        .overlay(Capsule(style: .circular).strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: TFOption<Value>, size: TFControlSize) -> some View {
        let selected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            HStack(spacing: 5) {
                if let symbol = option.systemImage {
                    Image(systemName: symbol).font(.system(size: size.iconSize + 1, weight: .medium))
                }
                if !option.title.isEmpty {
                    Text(option.title)
                    if let count = option.count {
                        Text(verbatim: "\(count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(selected ? TFColors.textSecondary : TFColors.textTertiary)
                    }
                }
            }
            .font(.system(size: size.segmentFontSize, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? TFColors.textPrimary : TFColors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, size.segmentHorizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: size.segmentItemHeight)
            .background {
                if selected {
                    Capsule(style: .circular)
                        .fill(TFColors.raised)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .tfCapsuleFocusEffect()
        .help(option.help ?? "")
        .accessibilityLabel(option.help ?? (option.count.map { "\(option.title), \($0)" } ?? option.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier?(option.value) ?? (option.title.isEmpty ? option.help ?? "" : option.title))
    }
}

/// An entry in a pane list.
struct TFPaneItem<ID: Hashable>: Identifiable {
    enum Status: Equatable { case active, inactive }

    var id: ID
    var title: String
    var systemImage: String
    var status: Status?

    init(_ id: ID, _ title: String, systemImage: String, status: Status? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.status = status
    }
}

/// A titled group of panes.
struct TFPaneSection<ID: Hashable>: Identifiable {
    var title: String?
    var items: [TFPaneItem<ID>]

    var id: String { title ?? items.map { "\($0.id)" }.joined(separator: ",") }

    init(_ title: String? = nil, items: [TFPaneItem<ID>]) {
        self.title = title
        self.items = items
    }
}

/// Level 3 (spec §4.3): a vertical pane list for more than six sections or grouped sections.
/// In a compact layout it folds into a pane picker (`TFPanePicker`).
struct TFPaneList<ID: Hashable>: View {
    let sections: [TFPaneSection<ID>]
    @Binding var selection: ID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    if let title = section.title {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TFColors.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 0 : 14)
                            .padding(.bottom, 4)
                    }
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
            }
        }
        .frame(width: TFMetrics.paneListWidth)
    }

    private func row(_ item: TFPaneItem<ID>) -> some View {
        let selected = item.id == selection
        return Button { selection = item.id } label: {
            HStack(spacing: 9) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? TFColors.accent : TFColors.textSecondary)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let status = item.status {
                    TFStatusDot(level: status == .active ? .success : .neutral)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TFMetrics.paneRowHeight)
            .background(selected ? TFColors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous))
        }
        .buttonStyle(TFRowHoverStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The pane list as a pop-up button, for compact layouts.
struct TFPanePicker<ID: Hashable>: View {
    let sections: [TFPaneSection<ID>]
    @Binding var selection: ID

    var body: some View {
        TFPopUpButton(
            title: L("component.pane"),
            sections: sections.map { section in
                TFPopUpSection(title: section.title, options: section.items.map {
                    TFOption($0.id, $0.title, systemImage: $0.systemImage)
                })
            },
            selection: $selection,
            width: 200
        )
    }
}

/// A pane list beside its content, or a pane picker above it when the layout is compact.
struct TFPaneLayout<ID: Hashable, Content: View>: View {
    let sections: [TFPaneSection<ID>]
    @Binding var selection: ID
    @ViewBuilder var content: Content
    @Environment(\.tfCompactLayout) private var compact

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 16) {
                TFPanePicker(sections: sections, selection: $selection)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            HStack(alignment: .top, spacing: 18) {
                TFPaneList(sections: sections, selection: $selection)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Hover wash for list-like rows; selected rows keep their own fill.
struct TFRowHoverStyle: ButtonStyle {
    var selected = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous)
                    .fill(selected ? Color.clear : (configuration.isPressed ? TFColors.pressedOverlay
                            : (hovering ? TFColors.hoverOverlay : .clear)))
            )
            .onHover { hovering = $0 }
    }
}
