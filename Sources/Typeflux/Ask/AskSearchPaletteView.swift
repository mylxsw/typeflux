import AppKit
import SwiftUI

/// The ⌘K card: a field, the matching actions and conversations, and a
/// keyboard highlight that ↑/↓ move and Return runs. It hangs from the top of
/// the window over a dimmed transcript; Esc or a click outside closes it.
struct AskSearchPaletteView: View {
    let conversations: [AskConversationSummary]
    var available: [AskPaletteAction]
    var onAction: (AskPaletteAction) -> Void
    var onOpen: (String) -> Void
    var onClose: () -> Void
    @State private var query = ""
    @State private var state = AskPaletteState(actions: [], conversations: [], highlighted: nil)
    @Environment(\.interfaceStyle) private var style
    @FocusState private var focused: Bool

    static let width: CGFloat = 560
    static let listMaxHeight: CGFloat = 360

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                card(listHeight: Self.listHeight(in: geometry.size.height, style: style))
                    .askPopIn(anchor: .top)
                    .padding(.horizontal, 12)
                    .padding(.top, Self.topInset(in: geometry.size.height))
            }
        }
        .onExitCommand { onClose() }
        .onAppear {
            refresh()
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _ in refresh() }
        .onChange(of: conversations) { _ in refresh() }
        .onChange(of: available) { _ in refresh() }
        .background(TypefluxWindowKeyHandler { event in
            guard (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                  event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else { return false }
            if let delta = AskArrowKeyMonitor.delta(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                state.move(delta)
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76 { run(); return true }
            if event.keyCode == 53 { onClose(); return true }
            return false
        })
    }

    static func topInset(in height: CGFloat) -> CGFloat {
        height < 500 ? AskMetrics.titleBarRowHeight : AskMetrics.titleBarRowHeight + 18
    }

    static func chromeHeight(style: InterfaceStyle) -> CGFloat {
        TypefluxControlHeight.spotlightInput.value(for: style)
            + TypefluxControlHeight.toolbarItem.value(for: style)
            + (style.usesGlass ? TypefluxSpacing.regular.value(for: style) : 0) + 1
    }

    static func listHeight(in height: CGFloat, style: InterfaceStyle = .liquidGlass) -> CGFloat {
        max(0, min(listMaxHeight, height - topInset(in: height) - chromeHeight(style: style) - 12))
    }

    private func card(listHeight: CGFloat) -> some View {
        Group {
            if style.usesGlass {
                TypefluxGlassGroup(spacing: TypefluxSpacing.regular.value(for: style)) {
                    VStack(spacing: TypefluxSpacing.regular.value(for: style)) {
                        TypefluxGlassContainer(radius: .spotlightInput, placement: .inWindow) { input }
                        TypefluxSpotlightSurface(placement: .inWindow) { results(listHeight: listHeight) }
                    }
                }
            } else {
                TypefluxSpotlightSurface(placement: .inWindow) {
                    VStack(spacing: 0) {
                        input
                        Divider()
                        results(listHeight: listHeight)
                    }
                }
            }
        }
        .frame(maxWidth: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("ask.workspace.search.palette")
    }

    private var input: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3).fontWeight(.medium)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
            TextField(L("ask.search.placeholder"), text: $query)
                .accessibilityIdentifier("ask.workspace.search.field")
                .textFieldStyle(.plain)
                .font(.title3)
                .foregroundStyle(TypefluxColor.label.color)
                .focused($focused)
                .onSubmit(run)
            Button(action: onClose) {
                Text(verbatim: "esc")
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(TypefluxColor.label.color.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: style),
                                                     style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L("clipboard.hint.close"))
            .accessibilityLabel(L("clipboard.hint.close"))
            .accessibilityIdentifier("ask.workspace.search.close")
        }
        .padding(.horizontal, TypefluxSpacing.large.value(for: style))
        .frame(height: TypefluxControlHeight.spotlightInput.value(for: style))
    }

    private func results(listHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            list(maxHeight: listHeight).background(TypefluxColor.contentBackground.color)
            Divider()
            HStack(spacing: TypefluxSpacing.large.value(for: style)) {
                Text("↑↓ " + L("clipboard.hint.navigate"))
                Text("↵ " + L("ask.search.execute"))
                Spacer(minLength: 0)
                Text("esc " + L("clipboard.hint.close"))
            }
            .font(.footnote)
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
            .padding(.horizontal, TypefluxSpacing.large.value(for: style))
            .frame(height: TypefluxControlHeight.toolbarItem.value(for: style))
            .accessibilityIdentifier("ask.workspace.search.hints")
        }
    }

    private func list(maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !state.actions.isEmpty {
                        header(L("ask.search.actions"))
                        ForEach(Array(state.actions.enumerated()), id: \.element.id) { index, row in
                            rowView(row, index: index)
                        }
                    }
                    if !state.conversations.isEmpty {
                        header(L("ask.search.conversations"))
                        ForEach(Array(state.conversations.enumerated()), id: \.element.id) { index, row in
                            rowView(row, index: state.actions.count + index)
                        }
                    }
                    if state.rows.isEmpty {
                        Text(L(conversations.isEmpty ? "ask.history.empty" : "ask.history.searchEmpty"))
                            .font(.callout)
                            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 26)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: state.highlighted) { index in
                guard let index, state.rows.indices.contains(index) else { return }
                proxy.scrollTo(state.rows[index].id)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func rowView(_ row: AskPaletteRow, index: Int) -> some View {
        let highlighted = state.highlighted == index
        return Button { state.highlighted = index; run() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(row)).font(.body)
                    .foregroundStyle(TypefluxSpotlightRow.labelColor(selected: highlighted, secondary: true))
                    .frame(width: 18)
                Text(title(row)).font(.body)
                    .foregroundStyle(TypefluxSpotlightRow.labelColor(selected: highlighted))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing = trailing(row) {
                    Text(trailing).font(.subheadline)
                        .foregroundStyle(TypefluxSpotlightRow.labelColor(selected: highlighted, secondary: true))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: TypefluxControlHeight.spotlightRow.value(for: style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(TypefluxSpotlightRow(selected: highlighted))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { state.highlighted = index } }
        .id(row.id)
        .accessibilityIdentifier("ask.workspace.search.result." + row.id)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func symbol(_ row: AskPaletteRow) -> String {
        switch row {
        case let .action(action): return action.systemImage
        case .conversation: return "bubble.left"
        }
    }

    private func title(_ row: AskPaletteRow) -> String {
        switch row {
        case let .action(action): return L(action.titleKey)
        case let .conversation(item): return item.title
        }
    }

    private func trailing(_ row: AskPaletteRow) -> String? {
        switch row {
        case let .action(action): return action.shortcut
        case let .conversation(item): return AskPresentation.historyTimeLabel(item.updatedAt)
        }
    }

    private func refresh() {
        state = AskPaletteState.make(query: query, conversations: conversations, available: available)
    }

    private func run() {
        switch state.highlightedRow {
        case let .action(action)?: onAction(action)
        case let .conversation(item)?: onOpen(item.id)
        case nil: break
        }
    }
}
