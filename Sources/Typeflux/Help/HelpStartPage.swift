import SwiftUI

/// The first page: the ways into Typeflux as illustrated tiles that show the gesture, the
/// keywords the user has not tried, and what the launcher does without a keyword. The keys
/// drawn are the user's own; Ask has no key of its own because it is the launcher.
struct HelpStartPage: View {
    @ObservedObject var model: HelpOverlayModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    HelpEntryTile(title: L("help.start.voice.title"), detail: L("help.start.voice.detail"),
                                  action: L("help.start.try"), run: model.actions.close) {
                        HelpVoiceArt(keys: model.catalog.voiceKeys, openSettings: { model.openSettings(.shortcuts) })
                    }
                    HelpEntryTile(title: L("help.start.launcher.title"), detail: L("help.start.launcher.detail"),
                                  action: L("help.start.try"), run: model.openLauncher) {
                        HelpLauncherArt(keys: model.catalog.launcherKeys,
                                        openSettings: { model.openSettings(.shortcuts) })
                    }
                }
                HelpEntryTile(title: L("help.start.keywords.title"),
                              detail: L("help.start.keywords.detail", model.catalog.keywords.count),
                              action: L("help.start.keywords.all"), run: { model.show(.keywords) }) {
                    HelpKeywordArt(popular: popularKeywords)
                }
                .padding(.top, 12)
                untried
                tips
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    /// Keywords the user reaches for most, to show next to the illustration.
    private var popularKeywords: [HelpKeyword] {
        let candidates = model.catalog.keywords.filter { $0.isAvailable && $0.group != .system }
        return Array(candidates.sorted { $0.usageCount > $1.usageCount }.prefix(4))
    }

    @ViewBuilder private var untried: some View {
        let keywords = model.catalog.untriedKeywords()
        if !keywords.isEmpty {
            HelpGroupTitle(title: L("help.start.untried"))
            HStack(spacing: 12) {
                ForEach(keywords) { keyword in
                    HelpUntriedCard(keyword: keyword) { model.showKeyword(keyword.id) }
                }
                ForEach(keywords.count ..< 3, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 0) {
            HelpGroupTitle(title: L("help.start.tips"))
            // Two to a row, so longer languages wrap instead of cutting the text off.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                tip("equal.square", L("help.start.tip.calculator"))
                tip("app.badge", L("help.start.tip.apps"))
                tip("arrow.up", L("help.start.tip.recent"))
                tip("text.cursor", L("help.start.tip.selection"))
            }
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 15 : 7, style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
    }
}

/// A tile with an illustration on top and what it is below; the whole tile is the button.
struct HelpEntryTile<Art: View>: View {
    var title: String
    var detail: String
    var action: String
    var run: () -> Void
    @ViewBuilder var art: Art
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        Button(action: run) {
            VStack(spacing: 0) {
                art.frame(maxWidth: .infinity).frame(height: 118)
                    .background(HelpTheme.well(style))
                    .overlay(alignment: .bottom) { Rectangle().fill(HelpTheme.blockBorder(style)).frame(height: 1) }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Text(action + " →").font(.system(size: 12)).foregroundStyle(AskTheme.accentText)
                        .opacity(hovering ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(shape.fill(HelpTheme.blockFill(style)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(hovering ? AskTheme.accent.opacity(0.5) : HelpTheme.blockBorder(style)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// Repeats a 2.4 s cycle while the guide is open; still when Reduce Motion is on.
struct HelpLoop<Content: View>: View {
    var period: Double = 2.4
    @ViewBuilder var content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content(0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                content(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
            }
        }
    }
}

/// The voice key pressed down, the waveform while speaking and the words appearing.
struct HelpVoiceArt: View {
    var keys: [String]?
    var openSettings: () -> Void

    var body: some View {
        HelpLoop { phase in
            let pressed = phase > 0.12 && phase < 0.75
            HStack(spacing: 16) {
                HelpBigKeys(keys: keys, pressed: pressed, openSettings: openSettings)
                HStack(spacing: 3) {
                    ForEach(0 ..< 9, id: \.self) { index in
                        let wave = sin((phase * 2 + Double(index) * 0.11) * .pi * 2)
                        Capsule().fill(AskTheme.accent)
                            .frame(width: 3, height: pressed ? 8 + 20 * abs(wave) : 6)
                    }
                }
                .frame(height: 34)
                Rectangle().fill(AskTheme.separator).frame(width: 1, height: 34)
                let sample = L("help.start.voice.sample")
                let shown = Int(Double(sample.count) * min(1, max(0, (phase - 0.2) / 0.55)))
                HStack(spacing: 1) {
                    Text(String(sample.prefix(shown))).font(.system(size: 13, weight: .medium))
                    Rectangle().fill(AskTheme.accent).frame(width: 1.5, height: 15)
                }
                .frame(width: 110, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The launcher's keys, and Ask answering about the selection: one feature.
struct HelpLauncherArt: View {
    var keys: [String]?
    var openSettings: () -> Void

    var body: some View {
        HelpLoop { phase in
            HStack(spacing: 16) {
                HelpBigKeys(keys: keys, pressed: phase > 0.1 && phase < 0.3, openSettings: openSettings)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(AskTheme.accent)
                        Text(L("help.start.launcher.sample.question")).font(.system(size: 12))
                    }
                    Text(L("help.start.launcher.sample.answer")).font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AskTheme.composerSurface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
                .opacity(phase > 0.3 ? 1 : 0.35)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small launcher with a keyword typed and its result highlighted, and the user's
/// most used keywords beside it.
struct HelpKeywordArt: View {
    var popular: [HelpKeyword]
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 28) {
            HelpLoop { phase in
                let sample = L("help.start.keywords.sample.input")
                let shown = Int(Double(sample.count) * min(1, max(0, phase / 0.4)))
                let corner: CGFloat = style.usesGlass ? 11 : 8
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary)
                        HelpKeywordLabel(keyword: AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id),
                                         showsAliases: false)
                        Text(String(sample.prefix(shown))).font(.system(size: 13))
                        Rectangle().fill(AskTheme.accent).frame(width: 1.5, height: 14)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    HStack(spacing: 8) {
                        Image(systemName: "character.bubble").font(.system(size: 12))
                        Text(L("help.start.keywords.sample.output")).font(.system(size: 12))
                        Spacer(minLength: 0)
                        Text("↩").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HelpTheme.selection(style)))
                    .padding([.horizontal, .bottom], 4)
                    .opacity(phase > 0.45 ? 1 : 0)
                }
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(AskTheme.composerSurface))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(AskTheme.border))
            }
            if !popular.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(popular) { keyword in
                        HStack(spacing: 8) {
                            HelpKeywordLabel(keyword: keyword.keyword, showsAliases: false)
                            Text(keyword.title).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The large keycaps of a tile, or a "Not set" button when the user removed the shortcut.
struct HelpBigKeys: View {
    var keys: [String]?
    var pressed: Bool
    var openSettings: () -> Void

    var body: some View {
        if let keys, !keys.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 { Text("+").font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary) }
                    HelpKeycap(key: key, large: true, pressed: pressed)
                }
            }
        } else {
            Button(L("help.shortcuts.unset"), action: openSettings)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(AskTheme.accentText)
        }
    }
}

/// A keyword the user has not used yet: its label, name and what it does.
struct HelpUntriedCard: View {
    var keyword: HelpKeyword
    var open: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HelpKeywordLabel(keyword: keyword.keyword, showsAliases: false, large: true)
                    Text(keyword.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                }
                Text(keyword.detail.isEmpty ? keyword.title : keyword.detail)
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(HelpTheme.blockFill(style)))
            .overlay(shape.strokeBorder(hovering ? AskTheme.accent.opacity(0.5) : HelpTheme.blockBorder(style)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
