import SwiftUI

/// Colours and shapes the notes window shares with the conversation window.
enum AskNotesStyle {
    /// Tag dots: the same tag always gets the same colour.
    static let tagPalette: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemOrange), Color(nsColor: .systemGreen),
        Color(nsColor: .systemPurple), Color(nsColor: .systemPink), Color(nsColor: .systemTeal),
        Color(nsColor: .systemYellow), Color(nsColor: .systemIndigo)
    ]

    static func tagColor(_ tag: String) -> Color {
        // FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt32 = 2_166_136_261
        for byte in tag.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return tagPalette[Int(hash % UInt32(tagPalette.count))]
    }

    static func sourceColor(_ source: AskNoteSource) -> Color {
        switch source {
        case .chat: AskTheme.accent
        case .command: Color(nsColor: .systemPurple)
        case .screenshot: Color(nsColor: .systemTeal)
        case .manual: Color(nsColor: .systemGreen)
        case .import: Color(nsColor: .systemOrange)
        }
    }
}

/// A row's hover wash and selection, drawn like the conversation history's:
/// an accent glass pill, or the flat source-list grey in the classic style.
struct AskNotesRowBackground: ViewModifier {
    var selected: Bool
    var hovering: Bool
    var corner: CGFloat
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            ZStack {
                if hovering, !selected { shape.fill(AskTheme.hoverFill) }
                if selected {
                    if style.usesGlass {
                        shape.fill(AskTheme.accent.opacity(0.18))
                            .overlay(shape.strokeBorder(AskTheme.accent.opacity(0.4), lineWidth: 0.5))
                    } else {
                        shape.fill(AskClassic.selection)
                    }
                }
            }
        }
    }
}

extension View {
    func askNotesRow(selected: Bool, hovering: Bool, corner: CGFloat) -> some View {
        modifier(AskNotesRowBackground(selected: selected, hovering: hovering, corner: corner))
    }
}

/// The shelves: new note, library, sources, tags and Recently Deleted.
struct AskNotesSidebar: View {
    @ObservedObject var model: AskNotesViewModel
    var clearsTitleBar = true
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window has a full-size content view; this strip clears the traffic lights.
            Color.clear.frame(height: clearsTitleBar
                ? AskMetrics.sidebarTopInset - (style.usesGlass ? AskMetrics.sidebarPanelInset : 0) : 12)
            newNoteButton.padding(.horizontal, 10).padding(.bottom, 10)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    shelf(.all, symbol: "note.text", count: model.counts[.all] ?? 0)
                    shelf(.pinned, symbol: "pin", count: model.counts[.pinned] ?? 0)
                    shelf(.recent, symbol: "clock", count: model.counts[.recent] ?? 0)
                    if !model.sources.isEmpty {
                        group(L("ask.notes.shelf.sources"))
                        ForEach(AskNoteSource.allCases, id: \.self) { source in
                            if let count = model.sources[source], count > 0 {
                                shelf(.source(source), symbol: source.symbol, count: count,
                                      tint: AskNotesStyle.sourceColor(source))
                                if source == .command {
                                    ForEach(model.commands) { facet in
                                        shelf(.command(facet.name), symbol: nil, count: facet.count, child: true)
                                    }
                                }
                            }
                        }
                    }
                    group(L("ask.notes.shelf.tags"))
                    if model.tags.isEmpty {
                        Text(L("ask.notes.noTags")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 10).frame(height: 26)
                    }
                    ForEach(model.tags) { facet in
                        shelf(.tag(facet.name), symbol: nil, count: facet.count,
                              dot: AskNotesStyle.tagColor(facet.name),
                              locked: model.agentSettings != nil && model.isHiddenFromAgent(facet.name))
                            .contextMenu {
                                if model.agentSettings != nil {
                                    Button(L(model.isHiddenFromAgent(facet.name) ? "ask.notes.agent.showTag"
                                        : "ask.notes.agent.hideTag")) { model.toggleHiddenFromAgent(facet.name) }
                                }
                            }
                    }
                    Color.clear.frame(height: 8)
                    shelf(.trash, symbol: "trash", count: model.counts[.trash] ?? 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            footer
        }
        .accessibilityIdentifier("ask.notes.sidebar")
    }

    private var newNoteButton: some View {
        Button { model.createNote() } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                Text(L("ask.notes.new")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(verbatim: "⌘N").font(.system(size: 11, weight: .medium)).opacity(0.75)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: style.usesGlass ? 34 : 28)
            .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: style.ask.searchFieldCorner,
                                                             style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: style.ask.searchFieldCorner, style: .continuous))
        }
        .buttonStyle(AskPressableStyle.subtle)
        .accessibilityIdentifier("ask.notes.new")
        .accessibilityLabel(L("ask.notes.new"))
    }

    private func group(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    private func shelf(_ scope: AskNoteQuery.Scope, symbol: String?, count: Int, tint: Color? = nil,
                       dot: Color? = nil, child: Bool = false, locked: Bool = false) -> some View {
        AskNotesShelfRow(title: model.title(of: scope), symbol: symbol, count: count,
                         tint: tint, dot: dot, child: child,
                         locked: locked, active: model.scope == scope) { model.scope = scope }
    }

    /// Whether the agent may use the notebook, and which tags it cannot see.
    private var agentMenu: some View {
        Menu {
            Toggle(L("ask.notes.agent.enabled"), isOn: Binding(get: { model.agentEnabled }, set: model.setAgentEnabled))
            Text(L("ask.notes.agent.hint"))
            if !model.agentHiddenTags.isEmpty {
                Section(L("ask.notes.agent.hiddenTags")) {
                    ForEach(model.agentHiddenTags, id: \.self) { tag in
                        Button("#" + tag) { model.toggleHiddenFromAgent(tag) }
                    }
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12.5))
                .foregroundStyle(model.agentEnabled ? AskTheme.accent : StudioTheme.textTertiary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(model.agentEnabled ? AskTheme.accent : StudioTheme.textTertiary)
        .fixedSize()
        .help(L("ask.notes.agent.title"))
        .accessibilityLabel(L("ask.notes.agent.title"))
        .accessibilityIdentifier("ask.notes.agent")
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Image(systemName: "lock").font(.system(size: 10))
            Text(L("ask.notes.localOnly")).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 4)
            if model.agentSettings != nil { agentMenu }
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 0.5) }
    }
}

struct AskNotesShelfRow: View {
    var title: String
    var symbol: String?
    var count: Int
    var tint: Color?
    var dot: Color?
    var child = false
    var locked = false
    var active: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8).frame(width: 18)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tint ?? (active ? AskTheme.accent : StudioTheme.textSecondary))
                        .frame(width: 18)
                }
                Text(title).font(.system(size: child ? 12.5 : 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active || hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                if locked {
                    Image(systemName: "eye.slash").font(.system(size: 9.5)).foregroundStyle(StudioTheme.textTertiary)
                        .help(L("ask.notes.agent.hiddenHelp"))
                }
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.leading, child ? 37 : 10)
            .padding(.trailing, 10)
            .frame(height: child ? 26 : (style.usesGlass ? 32 : 28))
            .frame(maxWidth: .infinity, alignment: .leading)
            .askNotesRow(selected: active, hovering: hovering, corner: style.ask.sidebarRowCorner)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
