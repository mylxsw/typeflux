// swiftlint:disable file_length
import SwiftUI

/// The popover a quote pill opens for its question. The excerpt is drawn as an
/// accent-ruled quote, the question sits in a framed field whose placeholder
/// lines up with the caret, suggested questions are chips, and the actions are
/// Ask capsules rather than stock bordered buttons.
struct AskReferenceEditor: View {
    @State var reference: AskReference
    var save: (AskReference) -> Void
    var cancel: () -> Void
    var editing = false
    var byteBudget = 64000
    /// "Quote 2 of 3" when the editor opens from a pill in the composer tray.
    var position: String?
    /// Scrolls the transcript to the answer the excerpt came from.
    var locate: (() -> Void)?
    var remove: (() -> Void)?
    @FocusState private var focused: Bool

    /// One-tap questions, in the order of the selection bar.
    static let suggestions: [AskSelectionAction] = [.explain, .translate]

    static func exceedsBudget(_ reference: AskReference, budget: Int) -> Bool {
        reference.text.utf8.count + reference.question.utf8.count > budget
    }

    private var tooLarge: Bool { Self.exceedsBudget(reference, budget: byteBudget) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "text.bubble").foregroundStyle(AskTheme.accentText)
                Text(position ?? L("ask.references.question"))
                Spacer(minLength: 8)
                if let locate {
                    Button(action: locate) {
                        Label(L("ask.references.locate"), systemImage: "arrow.up.forward.square")
                            .font(.system(size: 12))
                            .foregroundStyle(AskTheme.accentText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            quote
            VStack(alignment: .leading, spacing: 8) {
                questionField
                HStack(spacing: 6) {
                    ForEach(Self.suggestions, id: \.rawValue) { action in
                        AskChip(
                            title: action.question,
                            systemImage: action.systemImage,
                            style: reference.question == action.question ? .active : .neutral,
                            action: { reference.question = action.question; focused = true }
                        )
                    }
                }
            }
            HStack(spacing: 8) {
                if let remove {
                    Button(L("ask.references.remove"), action: remove)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.danger)
                }
                if tooLarge {
                    Label(L("ask.input.tooLarge"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(L("common.cancel"), action: cancel)
                    .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(L(editing ? "ask.references.update" : "ask.references.save")) { save(reference) }
                    .buttonStyle(AskCapsuleButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩")
                    .disabled(tooLarge)
            }
        }
        .padding(20).frame(width: 440)
        .background(AskTheme.popoverSurface).tint(AskTheme.accent)
        .onAppear { focused = true }
    }

    private var quote: some View {
        ScrollView {
            Text(reference.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(StudioTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
        }
        .frame(maxHeight: 112)
        .fixedSize(horizontal: false, vertical: true)
        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(AskTheme.accent).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskTheme.border))
    }

    /// NSTextView pads its text by 5pt, so the placeholder takes the same inset
    /// and never sits under the caret.
    private var questionField: some View {
        ZStack(alignment: .topLeading) {
            if reference.question.isEmpty {
                Text(L("ask.references.optional"))
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $reference.question)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .accessibilityLabel(L("ask.references.optional"))
        }
        .padding(.horizontal, 7).padding(.vertical, 8)
        .frame(height: 84)
        .background(AskTheme.composerSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? AskTheme.accent.opacity(0.6) : AskTheme.border))
    }
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
    @State private var hovering = false

    static let height: CGFloat = 28
    static let corner: CGFloat = 9
    static let maxWidth: CGFloat = 190
    /// A typed question can be long; it keeps at most this much of the pill.
    static let labelMaxWidth: CGFloat = 104

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
                        AskCappedWidth(maxWidth: Self.labelMaxWidth) {
                            Text(label).fontWeight(.semibold).foregroundStyle(AskTheme.accentText)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .layoutPriority(1)
                        if case .question = intent {
                            Text("·").foregroundStyle(StudioTheme.textTertiary)
                        }
                    }
                    Text(reference.preview)
                        .foregroundStyle(highlighted ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onRemove {
                // Kept in the layout while hidden, so pills never re-wrap on hover.
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(AskTheme.pressFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(highlighted ? 1 : 0)
                .allowsHitTesting(highlighted)
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
        return AskFlowLayout(spacing: Self.spacing, itemMaxWidth: AskReferenceChip.maxWidth) {
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
                        .foregroundStyle(StudioTheme.textSecondary)
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
                        editing = nil
                    },
                    cancel: { editing = nil },
                    editing: true,
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

    var body: some View {
        AskFlowLayout(spacing: AskReferenceStrip.spacing, alignment: .trailing,
                      itemMaxWidth: AskReferenceChip.maxWidth) {
            ForEach(references) { reference in
                AskReferenceChip(reference: reference, style: .sent, action: { locate(reference.messageId) })
            }
        }
    }
}
