// swiftlint:disable file_length
import SwiftUI

/// The popover a quote pill opens, laid out as on the GUL-161 design board: a
/// header with the quote's position and "Locate source", the excerpt behind an
/// accent rule, a one-line question field with suggested questions, and a
/// footer with "Remove quote" and the keyboard hints. Like other macOS
/// popovers it keeps an edit when dismissed by clicking elsewhere; Esc
/// discards it.
struct AskReferenceEditor: View {
    @State var reference: AskReference
    var save: (AskReference) -> Void
    var cancel: () -> Void
    var byteBudget = 64000
    /// "Quote 2 / 3" when the tray holds several quotes.
    var position: String?
    /// Scrolls the transcript to the answer the excerpt came from.
    var locate: (() -> Void)?
    var remove: (() -> Void)?
    @State private var original: AskReference?
    @State private var finished = false
    @FocusState private var focused: Bool

    static let width: CGFloat = 360
    /// One-tap questions, in the order of the selection bar.
    static let suggestions: [AskSelectionAction] = [.explain, .translate]

    static func exceedsBudget(_ reference: AskReference, budget: Int) -> Bool {
        reference.text.utf8.count + reference.question.utf8.count > budget
    }

    /// Whether dismissing the popover should keep the edit.
    static func keepsOnDismiss(_ reference: AskReference, original: AskReference?, budget: Int) -> Bool {
        guard let original else { return false }
        return reference != original && !exceedsBudget(reference, budget: budget)
    }

    private var tooLarge: Bool { Self.exceedsBudget(reference, budget: byteBudget) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            quote.padding(.top, 10)
            questionField.padding(.top, 12)
            suggestionRow.padding(.top, 8)
            footer.padding(.top, 12)
        }
        .padding(14)
        .frame(width: Self.width)
        .background(AskTheme.popoverSurface)
        .tint(AskTheme.accent)
        .onAppear {
            original = reference
            focused = true
        }
        .onDisappear {
            if !finished, Self.keepsOnDismiss(reference, original: original, budget: byteBudget) { save(reference) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AskTheme.accentText)
            Text(position ?? L("ask.quote"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer(minLength: 8)
            if let locate {
                // Leaving for the source closes the popover, which keeps the edit.
                Button(action: locate) {
                    Label(L("ask.references.locate"), systemImage: "arrow.up.forward.square")
                        .font(.system(size: 12))
                        .foregroundStyle(AskTheme.accentText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var quote: some View {
        ScrollView {
            Text(reference.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(StudioTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 2)
        }
        .frame(maxHeight: 104)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .leading) {
            Rectangle().fill(AskTheme.accent).frame(width: 2)
        }
    }

    /// One line that grows to three, so a short question reads as a field
    /// rather than an empty text box. Return keeps the question.
    private var questionField: some View {
        TextField(L("ask.references.optional"), text: $reference.question, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(StudioTheme.textPrimary)
            .lineLimit(1...3)
            .focused($focused)
            .onSubmit(commit)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(AskTheme.composerSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? AskTheme.accent.opacity(0.6) : AskTheme.border))
    }

    private var suggestionRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.suggestions, id: \.rawValue) { action in
                let active = reference.question == action.question
                Button { reference.question = action.question; focused = true } label: {
                    Label(action.question, systemImage: action.systemImage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(active ? AskTheme.accentText : StudioTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(active ? AskTheme.accentSoft : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(active ? .clear : AskTheme.border))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let remove {
                Button(L("ask.references.remove")) { finish(); remove() }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.danger)
            }
            Spacer(minLength: 8)
            if tooLarge {
                Label(L("ask.input.tooLarge"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StudioTheme.warning)
                    .lineLimit(1)
            } else {
                // The hints are the buttons, so the shortcuts work and a pointer can use them.
                Button(L("ask.references.saveHint"), action: commit)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                Text("·")
                Button(L("ask.references.closeHint")) { finish(); cancel() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textTertiary)
    }

    private func commit() {
        guard !tooLarge else { return }
        finish()
        save(reference)
    }

    private func finish() { finished = true }
}

extension AskReference {
    /// What the quote asks for, which decides its pill's icon and label.
    enum Intent: Equatable {
        case quote, explain, translate
        case question(String)

        var systemImage: String {
            switch self {
            case .quote: return "quote.opening"
            case .explain: return AskSelectionAction.explain.systemImage
            case .translate: return AskSelectionAction.translate.systemImage
            case .question: return AskSelectionAction.ask.systemImage
            }
        }

        /// The accent label in front of the excerpt; a bare quote has none, so
        /// a row of plain quotes is not a row of identical "Selected excerpt" tags.
        var label: String? {
            switch self {
            case .quote: return nil
            case .explain: return AskSelectionAction.explain.title
            case .translate: return AskSelectionAction.translate.title
            case .question(let text): return text
            }
        }
    }

    var intent: Intent {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .quote }
        if trimmed == AskSelectionAction.explain.question { return .explain }
        if trimmed == AskSelectionAction.translate.question { return .translate }
        return .question(trimmed)
    }

    var preview: String { Self.preview(text) }

    /// One line of the excerpt for a pill. A selection taken from rendered
    /// Markdown can start mid-sentence or on a list item, so leading
    /// punctuation, list markers and blank lines are dropped and the lines are
    /// joined with spaces.
    static func preview(_ text: String) -> String {
        let marker = #"^(?:[-*+•·>]|\d{1,3}[.)、])\s*"#
        let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            var line = line.trimmingCharacters(in: .whitespaces)
            while let range = line.range(of: marker, options: .regularExpression), !range.isEmpty {
                line.removeSubrange(range)
            }
            return line.isEmpty ? nil : line
        }
        var joined = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let leading = CharacterSet.whitespaces.union(.punctuationCharacters)
        let trailing = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",，;；:：、"))
        while let first = joined.unicodeScalars.first, leading.contains(first) { joined.unicodeScalars.removeFirst() }
        while let last = joined.unicodeScalars.last, trailing.contains(last) { joined.unicodeScalars.removeLast() }
        return joined.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }
}

/// Lays its children out left to right and wraps them onto new rows, the way
/// quote pills and their trailing controls share the composer's width.
struct AskFlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading
    /// The widest a child may be; a single child may be widened by the caller.
    var itemMaxWidth: CGFloat = .infinity
    /// Sends the last child to the trailing edge of its row, the way "Clear"
    /// closes the tray on the design board.
    var pinsLastToTrailingEdge = false

    struct Row: Equatable {
        var indices: [Int]
        var width: CGFloat
        var height: CGFloat
    }

    /// Splits the measured sizes into rows no wider than `maxWidth`. A child
    /// wider than the row on its own is narrowed to fit.
    static func rows(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for (index, size) in sizes.enumerated() {
            let width = min(size.width, maxWidth)
            if !current.indices.isEmpty, current.width + spacing + width > maxWidth {
                rows.append(current)
                current = Row(indices: [], width: 0, height: 0)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    static func height(of rows: [Row], spacing: CGFloat) -> CGFloat {
        rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    }

    private func sizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return CGSize(width: min(ideal.width, itemMaxWidth), height: ideal.height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = sizes(subviews)
        let maxWidth = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }
        let rows = Self.rows(sizes: sizes, maxWidth: maxWidth, spacing: spacing)
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: Self.height(of: rows, spacing: spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let sizes = sizes(subviews)
        var top = bounds.minY
        for row in Self.rows(sizes: sizes, maxWidth: bounds.width, spacing: spacing) {
            var left = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let width = min(sizes[index].width, bounds.width)
                if pinsLastToTrailingEdge, index == sizes.count - 1, alignment != .trailing {
                    left = max(left, bounds.maxX - width)
                }
                subviews[index].place(at: CGPoint(x: left, y: top + (row.height - sizes[index].height) / 2),
                                      proposal: ProposedViewSize(width: width, height: sizes[index].height))
                left += width + spacing
            }
            top += row.height + spacing
        }
    }
}

/// One quoted excerpt as a single-line pill: an intent icon, an optional
/// accent label and the cleaned excerpt.
struct AskReferenceChip: View {
    enum Style { case draft, sent }

    let reference: AskReference
    var style: Style = .draft
    var selected = false
    var action: () -> Void
    var onRemove: (() -> Void)?
    /// Follows the pointer; starts false.
    @State var hovering = false

    static let height: CGFloat = 28
    static let corner: CGFloat = 9
    static let maxWidth: CGFloat = 188

    static func showsExcerpt(_ intent: AskReference.Intent) -> Bool {
        if case .question = intent { return false }
        return true
    }

    private var highlighted: Bool { hovering || selected }

    var body: some View {
        let intent = reference.intent
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: intent.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AskTheme.accentText)
                    if let label = intent.label {
                        Text(label).fontWeight(.semibold).foregroundStyle(AskTheme.accentText)
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    // A typed question says what the quote is for; its excerpt
                    // would only get a character or two, so it lives in the
                    // tooltip and the popover instead.
                    if Self.showsExcerpt(intent) {
                        Text(reference.preview)
                            .foregroundStyle(highlighted ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onRemove {
                // Kept in the layout while hidden, so pills never re-wrap on
                // hover. Only the pointer reveals it, as on the design board.
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(AskTheme.pressFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(true)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 9 : 6)
        .frame(height: Self.height)
        .background(fill, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(stroke))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .help(reference.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(reference))
        .accessibilityAddTraits(.isButton)
        .modifier(AskRemoveAction(remove: onRemove))
    }

    static func accessibilityLabel(_ reference: AskReference) -> String {
        [reference.intent.label ?? L("ask.references.source"), reference.preview].joined(separator: ": ")
    }

    private var fill: Color {
        if selected { return AskTheme.accentSoft }
        switch style {
        case .draft: return hovering ? AskTheme.hoverFill : AskTheme.hoverFill.opacity(0.75)
        case .sent: return hovering ? AskTheme.hoverFill : .clear
        }
    }

    private var stroke: Color {
        if selected { return AskTheme.accent.opacity(0.45) }
        return hovering || style == .sent ? AskTheme.border : AskTheme.separator
    }
}

/// Offers "Remove" to assistive technologies only on pills that can be removed;
/// the visual ✕ appears on hover alone.
private struct AskRemoveAction: ViewModifier {
    var remove: (() -> Void)?

    func body(content: Content) -> some View {
        if let remove {
            content.accessibilityAction(named: L("ask.remove"), remove)
        } else {
            content
        }
    }
}

/// Quotes waiting in the composer, as a tray of pills above the editor.
struct AskReferenceStrip: View {
    @Binding var references: [AskReference]?
    var locate: (String) -> Void
    @State private var editing: String?
    /// Whether every pill shows rather than "+N"; starts folded.
    @State var expanded = false

    /// Collapsed, the tray shows this many pills and folds the rest into "+N",
    /// which keeps it to two rows at the composer's width.
    static let collapsedLimit = 4
    static let spacing: CGFloat = 6
    /// Expanded, the tray is three pill rows tall and scrolls.
    static let maxExpandedHeight = AskReferenceChip.height * 3 + spacing * 2

    static func visibleCount(total: Int, expanded: Bool) -> Int {
        expanded ? max(total, 0) : min(max(total, 0), collapsedLimit)
    }

    /// The editor's prompt names how many quotes the question is about.
    static func placeholder(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return L("ask.references.placeholder.one")
        default: return L("ask.references.placeholder.many", count)
        }
    }

    var body: some View {
        let items = references ?? []
        Group {
            if items.count == 1, let only = items.first {
                // A lone quote takes the whole row and shows more of the excerpt.
                chip(only, index: 0, total: 1)
            } else if expanded {
                // Only reachable past `collapsedLimit`, so the list always fills
                // the three rows it scrolls within.
                ScrollView(.vertical) { tray(items) }
                    .frame(height: Self.maxExpandedHeight)
            } else {
                tray(items)
            }
        }
        .onChange(of: items.count) { count in
            if count <= Self.collapsedLimit { expanded = false }
        }
    }

    private func tray(_ items: [AskReference]) -> some View {
        let shown = Self.visibleCount(total: items.count, expanded: expanded)
        return AskFlowLayout(spacing: Self.spacing, itemMaxWidth: AskReferenceChip.maxWidth,
                             pinsLastToTrailingEdge: items.count > 1) {
            ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, reference in
                chip(reference, index: index, total: items.count)
            }
            if items.count > Self.collapsedLimit {
                Button { expanded.toggle() } label: {
                    Text(expanded ? L("ask.references.collapse") : "+\(items.count - shown)")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: AskReferenceChip.height)
                        .overlay(RoundedRectangle(cornerRadius: AskReferenceChip.corner, style: .continuous)
                            .strokeBorder(AskTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? L("ask.references.collapse") : L("ask.references.showAll", items.count))
            }
            if items.count > 1 {
                Button { editing = nil; references = nil } label: {
                    Text(L("ask.references.clear"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.horizontal, 6)
                        .frame(height: AskReferenceChip.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ reference: AskReference, index: Int, total: Int) -> some View {
        AskReferenceChip(reference: reference, selected: editing == reference.id,
                         action: { editing = reference.id },
                         onRemove: { remove(reference.id) })
            .popover(isPresented: Binding(
                get: { editing == reference.id },
                set: { if !$0, editing == reference.id { editing = nil } }
            ), arrowEdge: .top) {
                AskReferenceEditor(
                    reference: reference,
                    save: { updated in
                        references = Self.replacing(updated, in: references)
                        // A popover dismissed by opening another pill saves late;
                        // it must not close the one that replaced it.
                        if editing == updated.id { editing = nil }
                    },
                    cancel: { if editing == reference.id { editing = nil } },
                    byteBudget: Self.byteBudget(for: reference, in: references),
                    position: total > 1 ? L("ask.references.position", index + 1, total) : nil,
                    locate: { editing = nil; locate(reference.messageId) },
                    remove: { remove(reference.id) }
                )
            }
    }

    private func remove(_ id: String) {
        if editing == id { editing = nil }
        references = Self.removing(id, from: references)
    }

    /// An emptied list goes back to `nil`, the draft's "no quotes" state.
    static func removing(_ id: String, from references: [AskReference]?) -> [AskReference]? {
        let rest = (references ?? []).filter { $0.id != id }
        return rest.isEmpty ? nil : rest
    }

    static func replacing(_ updated: AskReference, in references: [AskReference]?) -> [AskReference]? {
        references?.map { $0.id == updated.id ? updated : $0 }
    }

    /// What one quote may grow to while the others keep their share of the
    /// request's 64 KB.
    static func byteBudget(for reference: AskReference, in references: [AskReference]?, total: Int = 64000) -> Int {
        total - (references ?? []).filter { $0.id != reference.id }
            .reduce(0) { $0 + $1.text.utf8.count + $1.question.utf8.count }
    }
}

/// The quotes a sent question carried: the same pills, outlined and read-only,
/// right-aligned above the bubble. A tap scrolls back to the quoted answer.
struct AskSentReferences: View {
    let references: [AskReference]
    var locate: (String) -> Void = { _ in }

    /// Three pills share one row of the bubble column.
    static let itemMaxWidth = ((AskMetrics.bubbleMaxWidth - AskReferenceStrip.spacing * 2) / 3).rounded(.down)

    var body: some View {
        AskFlowLayout(spacing: AskReferenceStrip.spacing, alignment: .trailing,
                      itemMaxWidth: Self.itemMaxWidth) {
            ForEach(references) { reference in
                AskReferenceChip(reference: reference, style: .sent, action: { locate(reference.messageId) })
            }
        }
    }
}
