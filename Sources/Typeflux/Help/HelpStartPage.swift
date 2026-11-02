import SwiftUI

/// The first page teaches the four core actions: pick one on the left, watch it on the stage,
/// follow its three steps and try it. Below come keywords the user has not used and what the
/// launcher does without a keyword. The keys drawn are the user's own.
struct HelpStartPage: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HelpPermissionBanner(model: model)
                HStack(alignment: .top, spacing: 24) {
                    intro.frame(width: 280)
                    HelpCoreActionScene(model: model, action: model.selectedAction)
                        .frame(maxWidth: .infinity)
                        .frame(height: 352)
                }
                HelpActionSteps(model: model, action: model.selectedAction).padding(.top, 14)
                untried
                tips
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(model.learnedActionCount > 0 ? "help.start.eyebrow.returning" : "help.start.eyebrow"))
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(AskTheme.accentText)
            Text(L("help.start.title"))
                .font(.studioDisplay(30, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
            Text(L("help.start.lead"))
                .font(.system(size: 13))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 16)
            VStack(spacing: 2) {
                ForEach(HelpCoreAction.allCases) { action in
                    HelpCoreActionRow(action: action, keys: model.catalog.keys(for: action),
                                      used: model.usageCount(action) > 0, selected: model.selectedAction == action) {
                        withAnimation(.easeOut(duration: 0.2)) { model.showAction(action) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var untried: some View {
        let keywords = model.catalog.untriedKeywords()
        if !keywords.isEmpty {
            HelpSectionHeader(title: L("help.start.untried"), detail: L("help.start.untried.detail"),
                              action: (L("help.start.keywords.all", model.catalog.keywords.count),
                                       { model.show(.keywords) }))
            HStack(alignment: .top, spacing: 12) {
                ForEach(keywords) { keyword in
                    HelpUntriedCard(keyword: keyword) { model.showKeyword(keyword.id) }
                }
                ForEach(keywords.count ..< 3, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 0) {
            HelpSectionHeader(title: L("help.start.tips"), detail: L("help.start.tips.detail"))
            HStack(alignment: .top, spacing: 12) {
                HelpTipCard(name: "calculator") {
                    Image(systemName: "equal.square")
                    Text("12*(3+4)")
                    Text("= 84").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioTheme.success)
                }
                HelpTipCard(name: "apps") {
                    Image(systemName: "app.badge")
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

/// One core action in the start page's list, as on the welcome screen.
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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.success)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                HelpKeycaps(keys: keys)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(shape.fill(selected ? HelpTheme.blockFill(style) : hovering ? AskTheme.hoverFill : .clear))
            .overlay(shape.strokeBorder(selected ? HelpTheme.blockBorder(style) : .clear))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(action.tint).frame(width: 3, height: 20)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.verb + " " + action.name)
        .accessibilityValue(used ? L("help.action.used.short") : L("help.action.untried"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The selected action's three steps, and the buttons that try it or lead further.
struct HelpActionSteps: View {
    @ObservedObject var model: HelpGuideModel
    var action: HelpCoreAction
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        let steps = action.steps
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(action.tint)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(action.tint.opacity(0.18)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font(.system(size: 13, weight: .semibold))
                        Text(step.detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) { Rectangle().fill(AskTheme.separator).frame(width: 1) }
            }
            VStack(spacing: 6) {
                HelpButton(title: model.practicingAction == action ? L("help.action.practice.done") : action.tryTitle,
                           prominent: true) { model.tryAction(action) }
                Button(action.moreTitle) { model.openMore(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(AskTheme.accentText)
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
    }
}

/// A missing permission on the start page: it stops the features being taught from working.
struct HelpPermissionBanner: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if let permission = model.missingPermissions.first {
            let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 12 : style.help.blockCorner,
                                         style: .continuous)
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(StudioTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("help.start.permission.title", permission.title)).font(.system(size: 12.5, weight: .semibold))
                    Text(permission.detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                HelpButton(title: L("help.faq.fix")) { model.fix(permission.id) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(shape.fill(StudioTheme.warning.opacity(0.11)))
            .overlay(shape.strokeBorder(StudioTheme.warning.opacity(0.3)))
            .padding(.bottom, 16)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) { sample }
                .font(.system(size: 12.5))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AskTheme.popoverSurface))
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(HelpTheme.well(style))
                .overlay(alignment: .bottom) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("help.start.tip.\(name).title")).font(.system(size: 12.5, weight: .semibold))
                Text(L("help.start.tip.\(name).detail")).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(shape.fill(HelpTheme.blockFill(style)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
        .accessibilityElement(children: .combine)
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

/// A keyword the user has not used yet: its name, what it does and what to type.
struct HelpUntriedCard: View {
    var keyword: HelpKeyword
    var open: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HelpSymbolTile(symbol: keyword.symbol, tint: keyword.group.tint)
                    Text(keyword.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    HelpKeywordLabel(keyword: keyword.keyword, showsAliases: false)
                }
                Text(keyword.detail.isEmpty ? keyword.title : keyword.detail)
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                Text(HelpKeywordDetail.examples(keyword).first ?? keyword.keyword.keyword)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AskTheme.hoverFill))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(HelpTheme.blockFill(style)))
            .overlay(shape.strokeBorder(hovering ? AskTheme.accent.opacity(0.5) : HelpTheme.blockBorder(style)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(keyword.title)
        .accessibilityHint(keyword.detail)
    }
}
