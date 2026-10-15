import SwiftUI

/// Case-, width- and diacritic-insensitive matching shared by every searchable list.
enum TFSearchMatcher {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty query matches everything; otherwise any field containing the query matches.
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let query = normalized(query)
        guard !query.isEmpty else { return true }
        return fields.contains { $0.range(of: query, options: options) != nil }
    }

    static func matches(_ query: String, _ fields: String...) -> Bool {
        matches(query, fields)
    }

    /// The first occurrence of the query in `text`, for highlighting.
    static func highlightRange(in text: String, query: String) -> Range<String.Index>? {
        let query = normalized(query)
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: options)
    }

    /// `text` with the first match emphasized in the accent color.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        guard let range = highlightRange(in: text, query: query),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result)
        else { return result }
        result[lower ..< upper].foregroundColor = TFColors.accent
        result[lower ..< upper].inlinePresentationIntent = .stronglyEmphasized
        return result
    }
}

/// What Escape does in a search field: clear the text first, then leave the field.
enum TFSearchEscapeAction: Equatable {
    case clear
    case resignFocus

    static func resolve(text: String) -> TFSearchEscapeAction {
        text.isEmpty ? .resignFocus : .clear
    }
}

/// Spec §7: the one search field. A 30pt capsule with a magnifying glass, a result count
/// and a clear button while there is text, and an optional ⌘F key cap.
struct TFSearchField: View {
    enum Placement {
        /// In a page toolbar: 200–320pt wide, responds to ⌘F and shows its key cap.
        case toolbar
        /// At the top of a list column, sheet or menu: as wide as its container.
        case container
    }

    let placeholder: String
    @Binding var text: String
    var placement: Placement = .toolbar
    /// Shown as "N items" while there is a query.
    var resultCount: Int?
    /// Focuses the field when it appears (used inside menus).
    var focusOnAppear = false
    /// ↓ from the field moves the selection into the results.
    var onMoveDown: (() -> Void)?
    var onSubmit: (() -> Void)?
    var identifier: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? TFColors.textSecondary : TFColors.textTertiary)
            field
            trailing
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .frame(height: TFControlSize.regular.height)
        .frame(minWidth: placement == .toolbar ? TFMetrics.searchMinWidth : nil,
               maxWidth: placement == .toolbar ? TFMetrics.searchMaxWidth : .infinity)
        .background(Capsule().fill(TFColors.control))
        .overlay {
            Capsule().strokeBorder(focused ? TFColors.accent : TFColors.border,
                                   lineWidth: focused ? 1 : TFMetrics.borderWidth)
        }
        .background {
            if focused {
                Capsule().inset(by: -TFMetrics.focusRingWidth / 2)
                    .stroke(TFColors.focusRing, lineWidth: TFMetrics.focusRingWidth)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .background { if placement == .toolbar { commandF } }
        .onAppear {
            if focusOnAppear {
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    @ViewBuilder private var field: some View {
        let field = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .accessibilityLabel(placeholder)
            .accessibilityValue(resultCount.map { L("settings.list.itemCount", $0) } ?? "")
            .onExitCommand {
                switch TFSearchEscapeAction.resolve(text: text) {
                case .clear: text = ""
                case .resignFocus: focused = false
                }
            }
            .onMoveCommand { direction in
                if direction == .down { onMoveDown?() }
            }
            .onSubmit { onSubmit?() }
        if let identifier {
            field.accessibilityIdentifier(identifier)
        } else {
            field
        }
    }

    @ViewBuilder private var trailing: some View {
        if !text.isEmpty {
            if let resultCount {
                Text(L("settings.list.itemCount", resultCount))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(TFColors.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button {
                text = ""
                focused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(TFColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("component.search.clear"))
        } else if placement == .toolbar && !focused {
            TFKeyCap(text: "⌘F")
        }
    }

    /// An invisible button that owns ⌘F for this window while the field is on screen.
    private var commandF: some View {
        Button("") { focused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// A keyboard shortcut drawn as a small key cap.
struct TFKeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(TFColors.textTertiary)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(TFColors.hoverOverlay, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
            .accessibilityHidden(true)
    }
}

/// Text with the search match emphasized.
struct TFHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(TFSearchMatcher.highlighted(text, query: query))
    }
}
