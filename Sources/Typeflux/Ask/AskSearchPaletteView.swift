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
                card(listHeight: Self.listHeight(in: geometry.size.height))
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
        .background(AskArrowKeyMonitor { delta in state.move(delta) })
    }

    static func topInset(in height: CGFloat) -> CGFloat {
        height < 500 ? AskMetrics.titleBarRowHeight : AskMetrics.titleBarRowHeight + 18
    }

    static func listHeight(in height: CGFloat) -> CGFloat {
        max(0, min(listMaxHeight, height - topInset(in: height) - 55 - 12))
    }

    private func card(listHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.search.placeholder"), text: $query)
                    .accessibilityIdentifier("ask.workspace.search.field")
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .focused($focused)
                    .onSubmit(run)
                Text(verbatim: "esc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .onTapGesture { onClose() }
                    .accessibilityLabel(L("ask.remove"))
                    .accessibilityIdentifier("ask.workspace.search.close")
                    .accessibilityAddTraits(.isButton)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            list(maxHeight: listHeight)
        }
        .frame(maxWidth: Self.width)
        .askInWindowGlass(corner: style.ask.paletteCorner, opaqueFill: AskTheme.popoverSurface,
                          elevation: .popover)
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
                            .font(.system(size: 12.5))
                            .foregroundStyle(StudioTheme.textTertiary)
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func rowView(_ row: AskPaletteRow, index: Int) -> some View {
        let highlighted = state.highlighted == index
        return Button { state.highlighted = index; run() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(row)).font(.system(size: 13))
                    .foregroundStyle(highlighted ? Color.white : StudioTheme.textSecondary)
                    .frame(width: 18)
                Text(title(row)).font(.system(size: 13.5))
                    .foregroundStyle(highlighted ? Color.white : StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing = trailing(row) {
                    Text(trailing).font(.system(size: 11))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.8) : StudioTheme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? AskTheme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: style.usesGlass ? 10 : 6, style: .continuous))
            .contentShape(Rectangle())
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

/// Delivers ↑ and ↓ to `onMove` while it is in the window, before the focused
/// text field turns them into caret moves. `onKeyPress` needs macOS 14.
struct AskArrowKeyMonitor: NSViewRepresentable {
    var onMove: (Int) -> Void

    static let upKeyCode: UInt16 = 126
    static let downKeyCode: UInt16 = 125

    /// The highlight step for a key, or nil when the key is not an arrow.
    static func delta(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return nil }
        switch keyCode {
        case upKeyCode: return -1
        case downKeyCode: return 1
        default: return nil
        }
    }

    final class MonitorView: NSView {
        var onMove: (Int) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      let delta = AskArrowKeyMonitor.delta(keyCode: event.keyCode, modifiers: event.modifierFlags)
                else { return event }
                self.onMove(delta)
                return nil
            }
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.onMove = onMove
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.removeFromSuperview()
    }
}
