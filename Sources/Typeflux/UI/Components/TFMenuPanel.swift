import SwiftUI

/// An option of a rich menu: icon, title, subtitle and an optional trailing note.
struct TFRichOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var subtitle: String?
    var systemImage: String?
    /// Tile color for the leading icon or initial.
    var tint: Color?
    var trailing: String?

    var id: Value { value }

    init(_ value: Value, _ title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color? = nil,
         trailing: String? = nil) {
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
    }
}

struct TFRichSection<Value: Hashable> {
    var title: String?
    var options: [TFRichOption<Value>]

    init(_ title: String? = nil, options: [TFRichOption<Value>]) {
        self.title = title
        self.options = options
    }

    /// Sections filtered by `query`; empty sections are dropped.
    static func filter(_ sections: [TFRichSection], query: String) -> [TFRichSection] {
        sections.compactMap { section in
            let options = section.options.filter {
                TFSearchMatcher.matches(query, [$0.title, $0.subtitle ?? "", $0.trailing ?? ""])
            }
            return options.isEmpty ? nil : TFRichSection(section.title, options: options)
        }
    }
}

/// Keyboard highlight movement over a flat list of values; wraps at both ends.
enum TFMenuHighlight {
    static func move<Value: Hashable>(_ current: Value?, in values: [Value], down: Bool) -> Value? {
        guard !values.isEmpty else { return nil }
        guard let current, let index = values.firstIndex(of: current) else {
            return down ? values.first : values.last
        }
        return values[(index + (down ? 1 : -1) + values.count) % values.count]
    }
}

/// Spec §5.4: the custom menu panel. Use it only when options need an icon, subtitle and
/// status, or when there are more than 12 options and the menu needs search; otherwise use
/// the native menu (`TFPopUpButton`).
struct TFMenuPanel<Value: Hashable>: View {
    let sections: [TFRichSection<Value>]
    var selection: Value?
    /// Nil decides from the option count (`TFLayout.menuNeedsSearch`).
    var searchable: Bool?
    var searchPlaceholder: String = L("component.search.placeholder")
    /// Menus focus their search field on open; an inline panel should not steal focus.
    var focusesSearch = true
    let onSelect: (Value) -> Void
    @State private var query = ""
    @State private var highlighted: Value?

    private var showsSearch: Bool {
        searchable ?? TFLayout.menuNeedsSearch(optionCount: sections.reduce(0) { $0 + $1.options.count })
    }

    var body: some View {
        let visible = TFRichSection.filter(sections, query: query)
        let values = visible.flatMap { $0.options.map(\.value) }
        VStack(alignment: .leading, spacing: 0) {
            if showsSearch {
                TFSearchField(placeholder: searchPlaceholder, text: $query, placement: .container,
                              resultCount: values.count, focusOnAppear: focusesSearch,
                              onMoveDown: { highlighted = TFMenuHighlight.move(highlighted, in: values, down: true) },
                              onSubmit: { if let value = highlighted ?? values.first { onSelect(value) } })
                    .padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { index, section in
                        if index > 0 {
                            Rectangle().fill(TFColors.border).frame(height: TFMetrics.borderWidth)
                                .padding(.vertical, 5).padding(.horizontal, 6)
                        }
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(TFColors.textTertiary)
                                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                        }
                        ForEach(section.options) { option in
                            TFMenuPanelRow(option: option, query: query, isSelected: option.value == selection,
                                           isHighlighted: option.value == highlighted) {
                                onSelect(option.value)
                            } onHover: { inside in
                                if inside { highlighted = option.value }
                            }
                        }
                    }
                    if visible.isEmpty {
                        Text(L("component.search.noResults", query))
                            .font(.system(size: 12))
                            .foregroundStyle(TFColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
            .frame(maxHeight: TFMetrics.menuMaxHeight)
        }
        .padding(TFMetrics.menuPadding)
        .frame(minWidth: 240, maxWidth: TFMetrics.menuMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(TFMenuPanelKeys(moveUp: { highlighted = TFMenuHighlight.move(highlighted, in: values, down: false) },
                                  moveDown: { highlighted = TFMenuHighlight.move(highlighted, in: values, down: true) },
                                  submit: { if let value = highlighted { onSelect(value) } }))
    }
}

/// ↑ / ↓ / Return inside the panel (macOS 14+; earlier systems use the search field's ↓ and Return).
private struct TFMenuPanelKeys: ViewModifier {
    var moveUp: () -> Void
    var moveDown: () -> Void
    var submit: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.upArrow) { moveUp(); return .handled }
                .onKeyPress(.downArrow) { moveDown(); return .handled }
                .onKeyPress(.return) { submit(); return .handled }
        } else {
            content
        }
    }
}

private struct TFMenuPanelRow<Value: Hashable>: View {
    let option: TFRichOption<Value>
    let query: String
    let isSelected: Bool
    let isHighlighted: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                if option.systemImage != nil || option.tint != nil {
                    TFIconTile(systemImage: option.systemImage, letter: option.title,
                               tint: option.tint ?? TFColors.accent, size: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(TFSearchMatcher.highlighted(option.title, query: isHighlighted ? "" : query))
                        .font(.system(size: 13))
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : TFColors.textSecondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                if let trailing = option.trailing {
                    Text(trailing)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : TFColors.textTertiary)
                }
            }
            .foregroundStyle(isHighlighted ? Color.white : TFColors.textPrimary)
            .padding(.leading, 6).padding(.trailing, 10)
            .frame(minHeight: option.subtitle == nil ? TFMetrics.menuItemHeight : TFMetrics.menuRichItemHeight)
            .background(isHighlighted ? TFColors.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel([option.title, option.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A pop-up style trigger that opens `TFMenuPanel` in a popover, for options that need
/// subtitles and status (e.g. model or server pickers).
struct TFRichPicker<Value: Hashable>: View {
    let title: String
    let sections: [TFRichSection<Value>]
    @Binding var selection: Value
    var width: CGFloat? = TFMetrics.formControlWideWidth
    var searchable: Bool?
    @State private var isPresented = false

    private var current: TFRichOption<Value>? {
        sections.lazy.flatMap(\.options).first { $0.value == selection }
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                if let current, current.systemImage != nil || current.tint != nil {
                    TFIconTile(systemImage: current.systemImage, letter: current.title,
                               tint: current.tint ?? TFColors.accent, size: 18)
                }
                Text(current?.title ?? title).fontWeight(.regular)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TFColors.textTertiary)
            }
            .frame(maxWidth: width == nil ? nil : .infinity)
        }
        .buttonStyle(TFButtonStyle(kind: .secondary))
        .frame(width: width)
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? "")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TFMenuPanel(sections: sections, selection: selection, searchable: searchable) { value in
                selection = value
                isPresented = false
            }
        }
    }
}
