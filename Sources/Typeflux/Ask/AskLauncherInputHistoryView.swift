import SwiftUI

/// Replaces the launcher's results; recall fills the editor and always searches again.
struct AskLauncherInputHistoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AskConversationModel
    @ObservedObject var store: AskLauncherInputHistoryStore
    @State private var confirmingClear = false
    var viewportHeight: CGFloat?

    static func height(count: Int) -> CGFloat {
        1 + AskLauncherSuggestions.listPadding * 2 + AskLauncherSuggestions.headerHeight
            + (count == 0 ? 120 : CGFloat(min(8, count)) * (AskLauncherSuggestions.rowHeight + 2))
    }

    var body: some View {
        let entries = model.launcherHistoryEntries
        let selected = model.highlightedLauncherHistory?.id
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 12)
            HStack {
                Text(L("ask.inputHistory.title"))
                Spacer()
                Text("↑ ↓")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: AskLauncherSuggestions.headerHeight)
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22))
                    Text(L(!store.enabled ? "ask.inputHistory.disabled" : model.launcherDraft.hasText
                           ? "ask.inputHistory.noMatches" : "ask.inputHistory.empty"))
                    Text(L(!store.enabled ? "ask.inputHistory.disabled.detail" : model.launcherDraft.hasText
                           ? "ask.inputHistory.noMatches.detail" : "ask.inputHistory.empty.detail"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ask.inputHistory.empty")
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, index: index, selected: selected == entry.id).id(entry.id)
                            }
                        }
                        .padding(.horizontal, AskLauncherSuggestions.listPadding)
                    }
                    .onChange(of: selected) { id in if let id { scroll.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .padding(.bottom, AskLauncherSuggestions.listPadding)
        .frame(height: min(Self.height(count: entries.count),
                           max(0, viewportHeight ?? Self.height(count: entries.count))))
        .accessibilityIdentifier("ask.inputHistory")
        .alert(L("ask.inputHistory.clear"), isPresented: $confirmingClear) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("ask.inputHistory.deleteAll"), role: .destructive) { store.clear() }
        } message: { Text(L("ask.inputHistory.clear.detail")) }
    }

    private func row(_ entry: AskLauncherInputHistory.Entry, index: Int, selected: Bool) -> some View {
        Button { model.fillLauncherInputHistory(entry) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(entry.destination)).aiSymbolTint(symbol(entry.destination))
                    .font(.system(size: 15))
                    .foregroundStyle(entry.destination == .unsent ? Color.orange : AskTheme.accent)
                    .frame(width: 26)
                if let keyword = entry.keyword {
                    Text(keyword).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(AskTheme.launcherSelection, in: RoundedRectangle(cornerRadius: 5))
                }
                Text(displayText(entry)).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(StudioTheme.textPrimary)
                if let caption = caption(entry) {
                    Text(caption)
                        .font(.system(size: 11)).lineLimit(1).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Text(L("ask.inputHistory.fill") + " →").font(.system(size: 10))
                        .foregroundStyle(AskTheme.accent)
                }
                Text(AskLauncherSuggestions.relative(entry.date, now: Date()))
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: AskLauncherSuggestions.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? selectionFill : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(AskTheme.accent.opacity(0.2), lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(AskLauncherNumberBadge(number: AskLauncherNumberShortcuts.number(at: index)))
        .accessibilityLabel(entry.text)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(L("ask.inputHistory.fill")) { model.fillLauncherInputHistory(entry) }
            Button(L("ask.inputHistory.askAI")) { model.askFromLauncherInputHistory(entry) }
            Button(L("ask.inputHistory.copy")) { AskQuickResults.copy(entry.text) }
            Divider()
            Button(L("ask.inputHistory.delete"), role: .destructive) { model.deleteLauncherInputHistory(entry) }
            Button(L("ask.inputHistory.clear"), role: .destructive) { confirmingClear = true }
        }
    }

    private var selectionFill: Color {
        colorScheme == .dark ? AskTheme.accent.opacity(0.12) : AskTheme.launcherSelection
    }

    private func caption(_ entry: AskLauncherInputHistory.Entry) -> String? {
        switch entry.destination {
        case .askAI: return L("ask.inputHistory.askAI")
        case .unsent: return L("ask.inputHistory.unsent")
        case .application, .file: return entry.label.isEmpty ? nil : "→ " + entry.label
        default: return entry.label.isEmpty ? nil : entry.label
        }
    }

    private func displayText(_ entry: AskLauncherInputHistory.Entry) -> String {
        let text = entry.keyword.map {
            entry.text.hasPrefix($0 + " ") ? String(entry.text.dropFirst($0.count + 1)) : entry.text
        }
            ?? entry.text
        return text.components(separatedBy: .newlines).joined(separator: " ↵ ")
    }

    private func symbol(_ destination: AskLauncherInputHistory.Destination) -> String {
        switch destination {
        case .askAI: "sparkles"
        case .calculation: "equal"
        case .application: "app"
        case .file: "doc"
        case .keyword: "command"
        case .web: "globe"
        case .unsent: "pencil"
        }
    }
}
