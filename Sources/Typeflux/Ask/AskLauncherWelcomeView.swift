import SwiftUI

/// The home with nothing to list: the conversation window's empty state, with the
/// keyword chips as starting points (`AskLauncherWelcome`).
struct AskLauncherWelcomeView: View {
    var chips: [AskLauncherHome.Chip]
    var teaching: Bool
    @Binding var highlighted: Int?
    var settings: SettingsStore
    var palette: AskOrbPalette = .brand
    var viewportHeight: CGFloat
    var onPick: (AskLauncherHome.Chip) -> Void
    /// Offered when application search is off, which is why the home is empty.
    var onEnableApps: (() -> Void)?
    var onHistory: (() -> Void)?

    private var layout: AskLauncherWelcome.Layout { AskLauncherWelcome.layout(viewport: viewportHeight) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                if layout.orbSize > 0 {
                    AskConversationOrb(size: layout.orbSize, palette: palette).padding(.bottom, 16)
                }
                Text(L("ask.empty")).font(.system(size: 20, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.bottom, 6)
                if layout.showsHint { AskShortcutHint(settings: settings) }
                if !chips.isEmpty {
                    Text(L(teaching ? "ask.home.section.tryKeywords" : "ask.home.section.keywords"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AskTheme.launcherMetaText)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                    AskFlowLayout(spacing: 6, alignment: .center) {
                        ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                            chipView(chip, selected: highlighted == index)
                        }
                    }
                    .frame(maxWidth: 560)
                }
                if let onEnableApps {
                    HStack(spacing: 4) {
                        Text(L("ask.launcher.welcome.appsOff"))
                        Button(L("ask.launcher.welcome.enableApps"), action: onEnableApps)
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(AskTheme.launcherMetaText)
                    .padding(.top, 14)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(height: viewportHeight, alignment: .top)
        .background(AskLauncherHomeKeyMonitor { key in handle(key) })
        .onChange(of: chips.count) { count in
            if let index = highlighted, index >= count { highlighted = nil }
        }
    }

    private func chipView(_ chip: AskLauncherHome.Chip, selected: Bool) -> some View {
        Button { onPick(chip) } label: {
            HStack(spacing: 6) {
                Image(systemName: chip.symbol).font(.system(size: 11))
                Text(chip.title).font(.system(size: 12.5)).lineLimit(1)
                Text(chip.keyword.keyword).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AskTheme.launcherKeywordText)
            }
            .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: AskLauncherSuggestions.chipHeight)
            .background(selected ? AskTheme.launcherSelection : AskTheme.launcherChipFill,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? AskTheme.launcherSelectionEdge : AskTheme.launcherChipEdge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.keyword.keyword + " " + chip.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func handle(_ key: AskLauncherHomeKeyMonitor.Key) -> Bool {
        if case .vertical(-1) = key, highlighted == nil, let onHistory {
            onHistory()
            return true
        }
        let move = AskLauncherWelcome.move(highlighted, key: key, count: chips.count)
        if move.handled { highlighted = move.highlight }
        return move.handled
    }
}
