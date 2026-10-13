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
    static let rowHeight: CGFloat = 36

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
        .background(AskArrowKeyMonitor { delta in state.move(delta) })
    }

    static func topInset(in height: CGFloat) -> CGFloat {
        height < 500 ? AskMetrics.titleBarRowHeight : AskMetrics.titleBarRowHeight + 18
    }

    static func listHeight(in height: CGFloat, style: InterfaceStyle = .liquidGlass) -> CGFloat {
        let header = TypefluxControlHeight.spotlightInput.value(for: style)
        let gap = TypefluxSpotlightMetrics.resultsSpacing(for: style) + (style == .classic ? 1 : 0)
        return max(0, min(listMaxHeight, height - topInset(in: height) - header - gap - 12))
    }

    private func card(listHeight: CGFloat) -> some View {
        TypefluxSpotlightLayout(placement: .inWindow) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .accessibilityHidden(true)
                TextField(L("ask.search.placeholder"), text: $query)
                    .accessibilityIdentifier("ask.workspace.search.field")
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(TypefluxColor.label.color)
                    .focused($focused)
                    .onSubmit(run)
            }
            .padding(.horizontal, 16)
            .frame(height: TypefluxControlHeight.spotlightInput.value(for: style))
        } modes: {
            TypefluxSpotlightModeControl(placement: .inWindow) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body)
                        .frame(width: style == .classic ? 30 : 56,
                               height: style == .classic ? 26 : 56)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                .help("Esc")
                .accessibilityLabel(L("ask.remove"))
                .accessibilityIdentifier("ask.workspace.search.close")
            }
            .padding(.trailing, style == .classic ? 10 : 0)
            .padding(.top, style == .classic ? 13 : 0)
        } results: {
            list(maxHeight: listHeight)
        }
        .frame(maxWidth: Self.width)
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
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(TypefluxSpotlightRow(selected: highlighted))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { state.highlighted = index } }
        .id(row.id)
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
