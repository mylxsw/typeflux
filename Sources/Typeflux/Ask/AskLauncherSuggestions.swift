import AppKit
import SwiftUI

/// A starting point the workspace offers while its composer is empty, and the
/// `/` palette's prompts. The launcher builds its own from what the user is
/// looking at (`AskLauncherHome`).
struct AskSuggestion: Equatable, Identifiable {
    var key: String
    var systemImage: String
    /// Attaches the current screenshot before sending.
    var screenshot = false

    var id: String { key }
    var title: String { L(key) }
    var caption: String { L(key + ".caption") }

    static let all: [AskSuggestion] = [
        AskSuggestion(key: "ask.suggest.screen", systemImage: "display", screenshot: true),
        AskSuggestion(key: "ask.suggest.selection", systemImage: "character.bubble"),
        AskSuggestion(key: "ask.suggest.page", systemImage: "globe")
    ]

    /// Moves a highlight among the suggestions, wrapping at both ends and
    /// passing over the ones that cannot run.
    static func step(_ index: Int, by delta: Int, count: Int = all.count, skipping disabled: Set<Int> = []) -> Int {
        guard count > 0 else { return 0 }
        var next = index
        for _ in 0 ..< count {
            next = ((next + delta) % count + count) % count
            if !disabled.contains(next) { return next }
        }
        return index
    }

    /// The highlight to start from: the given one, or the next that can run.
    static func available(_ index: Int, count: Int = all.count, skipping disabled: Set<Int>) -> Int {
        disabled.contains(index) ? step(index, by: 1, count: count, skipping: disabled) : index
    }
}

/// The launcher's home under its editor: a hairline, then the sections of
/// `AskLauncherHome` — actions for what the user is looking at, conversations
/// to continue, and keyword chips. ↑/↓ move between rows (the chip row is one
/// stop, ←/→ move along it), Return runs the highlight and ⌘1…⌘9 run a row.
struct AskLauncherSuggestions: View {
    var sections: [AskLauncherHome.Section]
    @Binding var highlighted: Int
    var onPick: (AskLauncherHome.Item) -> Void
    var now = Date()

    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    /// A section title sits at the bottom of its band: the space above it parts it
    /// from the previous section, the space below from its own rows.
    static let headerHeight: CGFloat = 34
    static let headerBottomGap: CGFloat = 6
    /// Keeps the chips as far below their title as a row's icon sits below its title.
    static let chipRowHeight: CGFloat = 44
    static let chipHeight: CGFloat = 28
    /// Rows, chips and titles all start their content this far in.
    static let contentInset: CGFloat = 10

    /// Everything the home adds to the launcher card; nothing when it is empty.
    static func height(for sections: [AskLauncherHome.Section]) -> CGFloat {
        guard !sections.isEmpty else { return 0 }
        let content = sections.reduce(CGFloat(0)) { total, section in
            switch section {
            case let .context(_, _, rows), let .recent(rows):
                let count = CGFloat(rows.count)
                return total + headerHeight + count * rowHeight + max(0, count - 1) * rowSpacing
            case .keywords:
                return total + headerHeight + chipRowHeight
            }
        }
        return 1 + listPadding * 2 + content
    }

    /// A typical home (three rows — a selection's actions or the recent conversations —
    /// and the chips), for placing the panel before its context has arrived.
    static let typicalHeight: CGFloat = {
        let rows = (0 ..< 3).map {
            AskLauncherHome.Row(id: "\($0)", title: "", symbol: "", tint: .accent, action: .ask(""))
        }
        return height(for: [.context(title: "", subtitle: nil, rows: rows), .keywords(chips: [], teaching: true)])
    }()

    /// What the bottom bar says Return does for the highlighted item, with ⌘K
    /// when there is captured context to open.
    static func hint(for item: AskLauncherHome.Item?, hasContext: Bool) -> String {
        let action: String
        switch item {
        case let .row(row):
            switch row.action {
            case .keyword: action = L("ask.home.hint.run")
            case .ask: action = L("ask.home.hint.ask")
            case .conversation: action = L("ask.home.hint.open")
            }
        case .chip: action = L("ask.home.hint.chip")
        case nil: return L(hasContext ? "ask.launcher.hint.context" : "ask.launcher.hint")
        }
        return ([action] + (hasContext ? [L("ask.home.hint.context")] : [])).joined(separator: " · ")
    }

    /// "just now", "12 min. ago": when a conversation was last active.
    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return L("ask.home.justNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private var items: [AskLauncherHome.Item] { AskLauncherHome.items(sections) }

    var body: some View {
        let items = self.items
        let numbers = Dictionary(uniqueKeysWithValues: AskLauncherHome.numberedRows(sections).enumerated()
            .map { ($0.element.id, $0.offset + 1) })
        let current = items.indices.contains(highlighted) ? items[highlighted].id : nil
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section, items: items, numbers: numbers, current: current)
                }
            }
            .padding(Self.listPadding)
        }
        .background(AskLauncherHomeKeyMonitor { key in handle(key, items: items) })
        .onAppear { clampHighlight(items.count) }
        .onChange(of: items.count) { clampHighlight($0) }
    }

    private func clampHighlight(_ count: Int) {
        if highlighted >= count || highlighted < 0 { highlighted = 0 }
    }

    private func handle(_ key: AskLauncherHomeKeyMonitor.Key, items: [AskLauncherHome.Item]) -> Bool {
        guard !items.isEmpty else { return false }
        switch key {
        case let .vertical(delta):
            highlighted = AskLauncherHome.move(highlighted, by: delta, in: items)
        case let .horizontal(delta):
            // ←/→ stay with the editor unless a chip is highlighted.
            guard items.indices.contains(highlighted), case .chip = items[highlighted] else { return false }
            highlighted = AskLauncherHome.move(highlighted, by: delta, in: items, horizontal: true)
        case let .number(number):
            let rows = AskLauncherHome.numberedRows(sections)
            guard rows.indices.contains(number - 1) else { return false }
            onPick(.row(rows[number - 1]))
        }
        return true
    }

    @ViewBuilder
    private func sectionView(_ section: AskLauncherHome.Section, items: [AskLauncherHome.Item],
                             numbers: [String: Int], current: String?) -> some View {
        switch section {
        case let .context(title, subtitle, rows):
            header(title, subtitle: subtitle)
            rowList(rows, items: items, numbers: numbers, current: current)
        case let .recent(rows):
            header(L("ask.home.section.recent"), subtitle: nil)
            rowList(rows, items: items, numbers: numbers, current: current)
        case let .keywords(chips, teaching):
            header(L(teaching ? "ask.home.section.tryKeywords" : "ask.home.section.keywords"), subtitle: nil)
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    let item = AskLauncherHome.Item.chip(chip)
                    chipView(chip, highlighted: item.id == current)
                        .onHover { if $0, let index = items.firstIndex(of: item) { highlighted = index } }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.contentInset)
            .frame(height: Self.chipRowHeight)
            .clipped()
        }
    }

    private func header(_ title: String, subtitle: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(StudioTheme.textSecondary)
            if let subtitle {
                Text(subtitle).foregroundStyle(StudioTheme.textSecondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, Self.contentInset)
        .padding(.bottom, Self.headerBottomGap)
        .frame(height: Self.headerHeight, alignment: .bottomLeading)
    }

    private func rowList(_ rows: [AskLauncherHome.Row], items: [AskLauncherHome.Item],
                         numbers: [String: Int], current: String?) -> some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(rows) { row in
                let item = AskLauncherHome.Item.row(row)
                rowView(row, number: numbers[row.id], highlighted: item.id == current)
                    .onHover { if $0, let index = items.firstIndex(of: item) { highlighted = index } }
            }
        }
    }

    static func tint(_ tint: AskLauncherHome.Tint) -> Color {
        switch tint {
        case .accent: return AskTheme.accent
        case .orange: return .orange
        case .purple: return .purple
        case .green: return .green
        case .neutral: return StudioTheme.textSecondary
        }
    }

    /// A row icon's tile: coloured actions keep a wash of their tint; neutral
    /// rows sit on a raised launcher tile instead of a grey wash.
    static func tileFill(_ tint: AskLauncherHome.Tint) -> Color {
        tint == .neutral ? AskTheme.launcherTile : Self.tint(tint).opacity(0.14)
    }

    static func tileEdge(_ tint: AskLauncherHome.Tint) -> Color {
        tint == .neutral ? AskTheme.launcherTileEdge : .clear
    }

    private func rowView(_ row: AskLauncherHome.Row, number: Int?, highlighted: Bool) -> some View {
        Button { onPick(.row(row)) } label: {
            HStack(spacing: 12) {
                tile(row)
                Text(row.title).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail = row.detail {
                    Text(detail).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let keyword = row.keyword { keywordLabel(keyword) }
                if let date = row.date {
                    Text(Self.relative(date, now: now)).font(.system(size: 11.5))
                        .foregroundStyle(AskTheme.launcherMetaText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Self.contentInset)
            .frame(height: Self.rowHeight)
            .background(highlighted ? AskTheme.launcherSelection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.launcherSelectionEdge)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .modifier(AskLauncherNumberBadge(number: number))
        .accessibilityHint(row.detail ?? "")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func tile(_ row: AskLauncherHome.Row) -> some View {
        Image(systemName: row.symbol).font(.system(size: 12.5))
            .foregroundStyle(Self.tint(row.tint))
            .frame(width: 28, height: 28)
            .background(Self.tileFill(row.tint), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Self.tileEdge(row.tint), lineWidth: 0.5))
    }

    private func keywordLabel(_ keyword: String) -> some View {
        Text(keyword).font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(AskTheme.accentText)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(AskTheme.launcherKeyword, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func chipView(_ chip: AskLauncherHome.Chip, highlighted: Bool) -> some View {
        Button { onPick(.chip(chip)) } label: {
            HStack(spacing: 6) {
                keywordLabel(chip.keyword.keyword)
                Text(chip.title).font(.system(size: 12.5))
                    .foregroundStyle(highlighted ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .frame(height: Self.chipHeight)
            .background(highlighted ? AskTheme.launcherSelection : AskTheme.launcherChipFill,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AskTheme.launcherChipEdge))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AskTheme.launcherSelectionEdge)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.keyword.keyword + " " + chip.title)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// The home's keys, read before the editor sees them: ↑/↓, ←/→ and ⌘1…⌘9.
/// The handler returns false to let a key through to the editor.
struct AskLauncherHomeKeyMonitor: NSViewRepresentable {
    enum Key: Equatable {
        case vertical(Int)
        case horizontal(Int)
        case number(Int)
    }

    var onKey: (Key) -> Bool

    static let leftKeyCode: UInt16 = 123
    static let rightKeyCode: UInt16 = 124

    /// The key an event stands for, or nil for every other key.
    static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Key? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if let digit = AskLauncherNumberShortcuts.number(keyCode: keyCode, modifiers: modifiers, characters: characters) {
            return .number(digit)
        }
        guard modifiers.isEmpty else { return nil }
        if let delta = AskArrowKeyMonitor.delta(keyCode: keyCode, modifiers: []) { return .vertical(delta) }
        switch keyCode {
        case leftKeyCode: return .horizontal(-1)
        case rightKeyCode: return .horizontal(1)
        default: return nil
        }
    }

    final class MonitorView: NSView {
        var onKey: (Key) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      let key = AskLauncherHomeKeyMonitor.key(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                              characters: event.charactersIgnoringModifiers)
                else { return event }
                if event.isARepeat, case .number = key { return nil }
                return self.onKey(key) ? nil : event
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
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.onKey = onKey
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.removeFromSuperview()
    }
}
