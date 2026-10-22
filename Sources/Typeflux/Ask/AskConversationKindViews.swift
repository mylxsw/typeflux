import SwiftUI

/// "Chat | Work" for a conversation that has not started: centred at the top of the
/// new-conversation page with labels, and icon-only at the start of the launcher's bar,
/// which keeps its empty space for dragging the panel.
struct AskConversationKindSwitch: View {
    let selection: AskConversationKind
    var compact = false
    var onSelect: (AskConversationKind) -> Void
    @Environment(\.interfaceStyle) private var style

    private var height: CGFloat { compact ? 26 : AskMetrics.headerCapsuleHeight }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AskConversationKind.allCases, id: \.self) { kind in
                let chosen = selection == kind
                Button { onSelect(kind) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol).font(.system(size: compact ? 11 : 12, weight: .medium))
                        if !compact {
                            Text(L(kind.titleKey))
                                .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(chosen ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .padding(.horizontal, compact ? 7 : 16)
                    .frame(height: height - 6)
                    .background {
                        if chosen {
                            Capsule(style: .continuous)
                                .fill(style.usesGlass ? AskTheme.controlSurface : AskClassic.card)
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L(kind.titleKey) + " · " + L(kind.titleKey + ".help"))
                .accessibilityLabel(L(kind.titleKey))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("ask.kind." + kind.rawValue)
            }
        }
        .padding(3)
        .frame(height: height)
        .background {
            if compact { Capsule(style: .continuous).fill(AskTheme.hoverFill) }
        }
        .modifier(AskKindSwitchSurface(enabled: !compact, height: height))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.kind.switch"))
    }
}

/// The full-size switch floats on the same glass capsule as the header's title.
private struct AskKindSwitchSurface: ViewModifier {
    let enabled: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        if enabled { content.askInWindowGlassPill(height: height) } else { content }
    }
}

/// The sidebar's kind filter: all conversations, chats or work.
struct AskHistoryKindBar: View {
    @Binding var selection: AskConversationKind?
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 2) {
            segment(nil, title: L("ask.history.filter.all"))
            ForEach(AskConversationKind.allCases, id: \.self) { segment($0, title: L($0.titleKey)) }
        }
        .padding(2)
        .frame(height: AskHistoryFilterBar.height)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: style.ask.filterCorner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.history.kindFilter"))
    }

    private func segment(_ kind: AskConversationKind?, title: String) -> some View {
        let chosen = selection == kind
        return Button { selection = kind } label: {
            Text(title).font(.system(size: 12, weight: chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: AskHistoryFilterBar.height - 4)
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: style.ask.filterCorner - 2, style: .continuous)
                            .fill(style.usesGlass ? AskTheme.controlSurface : AskClassic.card)
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: style.ask.filterCorner - 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("ask.history.kind." + (kind?.rawValue ?? "all"))
    }
}

/// Where conversations are kept, as a compact menu beside the kind filter. It only
/// appears while the list mixes Cloud conversations with ones kept on this Mac.
struct AskHistoryStorageMenu: View {
    @Binding var selection: AskHistoryFilter

    var body: some View {
        Menu {
            ForEach(AskHistoryFilter.allCases, id: \.self) { filter in
                Button { selection = filter } label: {
                    if selection == filter { Label(L(filter.titleKey), systemImage: "checkmark") }
                    else { Text(L(filter.titleKey)) }
                }
            }
        } label: {
            Image(systemName: selection.symbol ?? "line.3.horizontal.decrease")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selection == .all ? StudioTheme.textSecondary : AskTheme.accent)
                .frame(width: AskHistoryFilterBar.height, height: AskHistoryFilterBar.height)
                .background(AskTheme.hoverFill, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("ask.history.filter"))
        .accessibilityLabel(L("ask.history.filter"))
        .accessibilityIdentifier("ask.history.storageFilter")
    }
}

extension Array where Element == AskConversationSummary {
    /// nil keeps every conversation.
    func filtered(kind: AskConversationKind?) -> [AskConversationSummary] {
        guard let kind else { return self }
        return filter { $0.resolvedKind == kind }
    }
}
