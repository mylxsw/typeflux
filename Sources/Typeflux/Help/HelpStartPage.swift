import SwiftUI

/// The first page: the ways into Typeflux as illustrated tiles that show the gesture, the
/// keywords the user has not tried, and what the launcher does without a keyword. The keys
/// drawn are the user's own; Ask has no key of its own because it is the launcher.
struct HelpStartPage: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Equal heights, so the two tiles line up whatever their text.
                HStack(alignment: .top, spacing: 12) {
                    HelpEntryTile(title: L("help.start.voice.title"), detail: L("help.start.voice.detail")) {
                        HelpVoiceArt(keys: model.catalog.voiceKeys, openSettings: { model.openSettings(.shortcuts) })
                    }
                    HelpEntryTile(title: L("help.start.launcher.title"), detail: L("help.start.launcher.detail"),
                                  action: L("help.start.try"), run: model.openLauncher) {
                        HelpLauncherArt(keys: model.catalog.launcherKeys,
                                        openSettings: { model.openSettings(.shortcuts) })
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HelpEntryTile(title: L("help.start.keywords.title"),
                              detail: L("help.start.keywords.detail", model.catalog.keywords.count),
                              action: L("help.start.keywords.all"), run: { model.show(.keywords) }) {
                    HelpKeywordArt()
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
            // Chips keep their own width and wrap, so longer languages never cut the text off.
            HelpFlowLayout(spacing: 8) {
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
            Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
    }
}

/// An illustrated tile. Only entries with an action behave as buttons.
struct HelpEntryTile<Art: View>: View {
    var title: String
    var detail: String
    var action: String?
    var run: (() -> Void)?
    @ViewBuilder var art: Art
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        if let run {
            Button(action: run) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        } else {
            content
        }
    }

    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        return VStack(spacing: 0) {
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
                if let action {
                    Text(action + " →").font(.system(size: 12)).foregroundStyle(AskTheme.accentText)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(hovering ? AskTheme.accent.opacity(0.5) : HelpTheme.blockBorder(style)))
        .contentShape(shape)
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

/// Holding the voice key: the key goes down, the waveform moves and the words are there.
/// Everything is drawn in every frame; the motion only accents it.
struct HelpVoiceArt: View {
    var keys: [String]?
    var openSettings: () -> Void

    var body: some View {
        HelpLoop { phase in
            let pressed = phase > 0.1 && phase < 0.8
            HStack(spacing: 16) {
                HelpBigKeys(keys: keys, pressed: pressed, accent: true, openSettings: openSettings)
                HStack(spacing: 3) {
                    ForEach(0 ..< 9, id: \.self) { index in
                        let wave = abs(sin((phase * 2 + Double(index) * 0.13) * .pi * 2))
                        Capsule().fill(AskTheme.accent)
                            .frame(width: 3, height: pressed ? 8 + 20 * wave : 6 + 10 * wave)
                    }
                }
                .frame(width: 52, height: 34)
                Rectangle().fill(AskTheme.separator).frame(width: 1, height: 34)
                HStack(spacing: 1) {
                    Text(L("help.start.voice.sample")).font(.system(size: 13, weight: .medium))
                    HelpCaret(phase: phase)
                }
                .fixedSize()
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
        HStack(spacing: 16) {
            HelpBigKeys(keys: keys, pressed: false, accent: false, openSettings: openSettings)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(StudioTheme.aiIcon)
                    Text(L("help.start.launcher.sample.question")).font(.system(size: 12, weight: .medium))
                }
                Text(L("help.start.launcher.sample.answer")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AskTheme.popoverSurface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .accessibilityHidden(true)
    }
}

/// A small launcher with a keyword typed and its highlighted result, as it looks in use.
struct HelpKeywordArt: View {
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let corner: CGFloat = style.usesGlass ? 11 : 8
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        HelpLoop(period: 1.1) { phase in
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                    HelpKeywordLabel(keyword: AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id),
                                     showsAliases: false)
                    Text(L("help.start.keywords.sample.input")).font(.system(size: 13))
                    HelpCaret(phase: phase)
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
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(HelpTheme.selectionEdge(style)))
                .padding([.horizontal, .bottom], 4)
            }
            .frame(width: 320)
            .background(shape.fill(AskTheme.popoverSurface))
            .overlay(shape.strokeBorder(AskTheme.border))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
        }
        .accessibilityHidden(true)
    }
}

/// A text cursor that blinks once a cycle.
struct HelpCaret: View {
    var phase: Double

    var body: some View {
        Rectangle().fill(AskTheme.accent).frame(width: 1.5, height: 15)
            .opacity(phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0)
    }
}

/// The large keycaps of a tile, or a "Not set" button when the user removed the shortcut.
/// Only the voice key lights up when pressed; the launcher's keys stay neutral.
struct HelpBigKeys: View {
    var keys: [String]?
    var pressed: Bool
    var accent: Bool
    var openSettings: () -> Void

    var body: some View {
        if let keys, !keys.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("+").font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    HelpKeycap(key: key, large: true, pressed: accent && pressed)
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

/// Lays children out left to right at their own size, wrapping onto the next line.
struct HelpFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let frames = Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) },
                                 width: proposal.width ?? .infinity, spacing: spacing)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let frames = Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width,
                                 spacing: spacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where each item goes: along a line until the next would pass `width`, then on a new line.
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for size in sizes {
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
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
