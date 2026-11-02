import SwiftUI

/// The first page: pick a core action, watch it on the stage, try it. Below are keywords the
/// user has not used and what the launcher does by itself. Explanations wait on hover.
struct HelpStartPage: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HelpPermissionBanner(model: model)
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        ForEach(HelpCoreAction.allCases) { action in
                            HelpCoreActionRow(action: action, keys: model.catalog.keys(for: action),
                                              used: model.usageCount(action) > 0,
                                              selected: model.selectedAction == action) {
                                withAnimation(.easeOut(duration: 0.2)) { model.showAction(action) }
                            }
                        }
                    }
                    .frame(width: 264)
                    HelpCoreActionScene(model: model, action: model.selectedAction)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 320)
                HelpActionSteps(model: model, action: model.selectedAction).padding(.top, 12)
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
            HelpSectionHeader(title: L("help.start.untried"))
            HStack(spacing: 12) {
                ForEach(keywords) { keyword in
                    HelpUntriedCard(keyword: keyword) { model.showKeyword(keyword.id) }
                }
                ForEach(keywords.count ..< 3, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 0) {
            HelpSectionHeader(title: L("help.start.tips"))
            HStack(alignment: .top, spacing: 12) {
                HelpTipCard(name: "calculator") {
                    Text("12*(3+4)")
                    Text("= 84").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioTheme.success)
                }
                HelpTipCard(name: "apps") {
                    Text("saf")
                    Text("→ Safari").foregroundStyle(StudioTheme.textTertiary)
                }
                HelpTipCard(name: "recent") {
                    HelpKeycap(key: "↑")
                    Text(L("help.start.tip.recent.sample")).foregroundStyle(StudioTheme.textSecondary)
                }
                HelpTipCard(name: "selection") {
                    Image(systemName: "text.cursor")
                    Text(L("help.start.tip.selection.sample"))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(AskTheme.accent.opacity(0.32)))
                }
            }
        }
    }
}

/// One core action in the start page's list. Its color appears only while it is selected.
struct HelpCoreActionRow: View {
    var action: HelpCoreAction
    var keys: [String]?
    var used: Bool
    var selected: Bool
    var select: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 12 : style.help.rowCorner, style: .continuous)
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? action.tint : StudioTheme.textSecondary)
                    .frame(width: 20)
                Text(action.verb)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                Text(action.name)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if used {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(StudioTheme.success)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                HelpKeycaps(keys: keys)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(selected ? HelpTheme.blockFill(style) : hovering ? AskTheme.hoverFill : .clear))
            .overlay(shape.strokeBorder(selected ? HelpTheme.blockBorder(style) : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.verb + " " + action.name)
        .accessibilityValue(used ? L("help.action.used.short") : L("help.action.untried"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The selected action in three words and the button that tries it. Each step's explanation
/// is its tooltip.
struct HelpActionSteps: View {
    @ObservedObject var model: HelpGuideModel
    var action: HelpCoreAction

    var body: some View {
        let steps = action.steps
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(step.title)
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(step.detail)
                    .accessibilityHint(step.detail)
            }
            Spacer(minLength: 8)
            HelpButton(title: model.practicingAction == action ? L("help.action.practice.done") : action.tryTitle,
                       prominent: true) { model.tryAction(action) }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

/// A missing permission stops what this page teaches, so it comes first. Why is its tooltip.
struct HelpPermissionBanner: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if let permission = model.missingPermissions.first {
            let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 12 : style.help.blockCorner,
                                         style: .continuous)
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioTheme.warning)
                Text(L("help.start.permission.title", permission.title)).font(.system(size: 13))
                Spacer(minLength: 8)
                HelpButton(title: L("help.faq.fix")) { model.fix(permission.id) }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(shape.fill(StudioTheme.warning.opacity(0.1)))
            .help(permission.detail)
            .padding(.bottom, 14)
        }
    }
}

/// Something the launcher does by itself: a small picture of it over its name.
struct HelpTipCard<Sample: View>: View {
    /// Names the strings, `help.start.tip.<name>.title` and `.detail`.
    var name: String
    @ViewBuilder var sample: Sample
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        VStack(spacing: 10) {
            HStack(spacing: 7) { sample }
                .font(.system(size: 12.5))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 22)
                .accessibilityHidden(true)
            Text(L("help.start.tip.\(name).title"))
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
        .help(L("help.start.tip.\(name).detail"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("help.start.tip.\(name).detail"))
    }
}

/// Repeats a cycle while the guide is open; holds `stillPhase` when Reduce Motion is on.
struct HelpLoop<Content: View>: View {
    var period: Double = 2.4
    /// The moment to hold: the scene with everything already on it.
    var stillPhase: Double = 0.5
    @ViewBuilder var content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content(stillPhase)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                content(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
            }
        }
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

/// A keyword the user has not used yet. What it does is its tooltip.
struct HelpUntriedCard: View {
    var keyword: HelpKeyword
    var open: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        Button(action: open) {
            HStack(spacing: 10) {
                HelpKeywordLabel(keyword: keyword.keyword, showsAliases: false)
                Text(keyword.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(shape.fill(hovering ? AskTheme.hoverFill : HelpTheme.blockFill(style)))
            .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(keyword.detail)
        .accessibilityLabel(keyword.title)
        .accessibilityHint(keyword.detail)
    }
}
