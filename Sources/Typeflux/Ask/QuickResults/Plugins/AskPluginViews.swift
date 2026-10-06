// swiftlint:disable file_length
import AppKit
import SwiftUI

/// What the launcher shows in keyword mode, as one value: the views draw it
/// and its height is known before they do, so the panel can size itself first.
struct AskPluginDisplay: Equatable {
    /// Only the keyword was typed: offer it.
    var hint: AskKeyword?
    var title: String
    var symbol: String
    /// What ⇥ changes, when it changes anything.
    var optionName: String?
    var phase: AskPluginSession.Phase
    var previous: AskPluginOutput?
    /// The result so far while it streams in.
    var partial: AskPluginOutput?
    var comparing = false
    /// 0 is the plugin's row or card, 1 is "Ask AI".
    var highlighted = 0

    var output: AskPluginOutput? { if case let .done(_, output) = phase { output } else { nil } }
    var asksAI: Bool { highlighted == 1 }
    /// A workflow's actions after this run, success or failure.
    var followUp: AskWorkflowFollowUp? {
        switch phase {
        case let .done(_, output): output.followUp
        case let .failed(_, failure): failure.followUp
        default: nil
        }
    }
}

/// The keyword as a chip at the start of the launcher's editor: "文A 翻译 → 日语".
struct AskKeywordChip: View {
    var title: String
    var symbol: String
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text("→ " + detail).font(.system(size: 12.5)).opacity(0.8)
            }
        }
        .foregroundStyle(AskTheme.accent)
        .padding(.leading, 5).padding(.trailing, 10)
        .frame(height: 30)
        .background(AskTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { title + " → " + $0 } ?? title)
        .accessibilityIdentifier("ask.plugin.keyword")
    }
}

/// The results area in keyword mode: the plugin's row or result card, then "Ask AI".
struct AskPluginResultsView: View {
    var display: AskPluginDisplay
    var question: String
    var minimumHeight: CGFloat = 0
    /// Return on the plugin's row: run, or the result's main action.
    var onMain: () -> Void
    var onAction: (AskPluginAction) -> Void
    var onAskAI: () -> Void
    var onHighlight: (Int) -> Void

    // Shared with the quick results, so both lists line up.
    static let listPadding = AskQuickResultsView.listPadding
    static let rowSpacing = AskQuickResultsView.rowSpacing
    static let sectionHeight = AskQuickResultsView.sectionHeight
    static let rowHeight: CGFloat = 46
    static let askHeight = AskQuickResultsView.askHeight
    static let cardPadding = EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14)
    static let headerHeight: CGFloat = 22
    static let actionsHeight: CGFloat = 24
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let bodyLineSpacing: CGFloat = 3
    static let maximumBodyHeight: CGFloat = 168
    static let originalFont = NSFont.systemFont(ofSize: 12.5)
    static let maximumOriginalHeight: CGFloat = 64
    static let noteHeight: CGFloat = 16
    static let skeletonHeight: CGFloat = 44
    static let caret = " ▍"
    private static let bodyID = "ask.plugin.body"

    /// The width text wraps to inside a card in the launcher.
    static var textWidth: CGFloat {
        AskMetrics.launcherWidth - AskMetrics.launcherGutter * 2 - listPadding * 2
            - cardPadding.leading - cardPadding.trailing
    }

    static func textHeight(_ text: String, font: NSFont, lineSpacing: CGFloat = 0, width: CGFloat = textWidth) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style]
        )
        return ceil(rect.height)
    }

    static func bodyHeight(_ text: String) -> CGFloat {
        min(maximumBodyHeight, max(22, textHeight(text, font: bodyFont, lineSpacing: bodyLineSpacing)))
    }

    static func originalHeight(_ text: String) -> CGFloat {
        min(maximumOriginalHeight, textHeight(text, font: originalFont))
    }

    /// The card's height for a result: header, the text (and the original when
    /// comparing), a note, and the actions.
    static func cardHeight(output: AskPluginOutput?, failure: AskPluginFailure?, comparing: Bool) -> CGFloat {
        var height = cardPadding.top + headerHeight + 8 + cardPadding.bottom
        if let output, let card = output.wordCard {
            height += AskWordCardView.height(card)
            if output.note != nil { height += 6 + noteHeight }
            height += 10 + actionsHeight
        } else if let output {
            if comparing { height += originalHeight(output.original) + 9 }
            height += bodyHeight(output.body)
            if output.note != nil { height += 6 + noteHeight }
            height += 10 + actionsHeight
        } else if let failure {
            height += textHeight(failure.message, font: .systemFont(ofSize: 13.5))
                + (failure.retry || !failure.actions.isEmpty ? 10 + actionsHeight : 0)
        } else {
            height += skeletonHeight
        }
        return height
    }

    static func mainHeight(_ display: AskPluginDisplay) -> CGFloat {
        if display.hint != nil { return askHeight }
        switch display.phase {
        case .waiting, .ready: return rowHeight
        case .running:
            return cardHeight(output: display.partial ?? display.previous, failure: nil, comparing: display.comparing)
        case let .done(_, output): return cardHeight(output: output, failure: nil, comparing: display.comparing)
        case let .failed(_, failure): return cardHeight(output: nil, failure: failure, comparing: false)
        }
    }

    /// Everything the list adds to the launcher card.
    static func height(for display: AskPluginDisplay) -> CGFloat {
        1 + listPadding * 2 + (sectionHeight + rowSpacing) * 2 + mainHeight(display) + rowSpacing + askHeight
    }

    /// What Return and the other keys do now, for the bottom bar.
    static func hint(for display: AskPluginDisplay) -> String {
        if display.hint != nil { return L("ask.plugin.hint.keyword") }
        if display.asksAI { return L("ask.launcher.hint") }
        let option = display.optionName.map { L("ask.plugin.hint.option", $0) }
        let parts: [String?]
        switch display.phase {
        case .waiting: return L("ask.plugin.hint.waiting")
        case let .ready(plan):
            if let action = plan.action(for: .enter) {
                parts = [L("ask.plugin.hint.action", action.title),
                         plan.action(for: .commandC).map { L("ask.plugin.hint.copy", $0.title) },
                         option, L("ask.plugin.hint.askAI")]
            } else {
                parts = [L("ask.plugin.hint.ready"), option, L("ask.plugin.hint.waiting")]
            }
        case .running: return L("ask.plugin.hint.running")
        case let .done(_, output):
            let main = output.action(for: .enter)?.title ?? ""
            parts = [output.action(for: .optionEnter).map { L("ask.plugin.hint.done", main, $0.title) }
                ?? L("ask.plugin.hint.action", main), option, L("ask.plugin.hint.askAI")]
        case let .failed(_, failure): return L(failure.retry ? "ask.plugin.hint.failed" : "ask.plugin.hint.waiting")
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: Self.rowSpacing) {
                section(display.hint != nil ? L("ask.plugin.section") : display.title)
                main
                    .onHover { if $0 { onHighlight(0) } }
                section(L("ask.quick.section.ai"))
                askRow
                    .onHover { if $0 { onHighlight(1) } }
            }
            .padding(Self.listPadding)
            Spacer(minLength: 0)
        }
        .frame(height: max(minimumHeight, Self.height(for: display)), alignment: .top)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Self.sectionHeight, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var main: some View {
        if let hint = display.hint {
            hintRow(hint)
        } else {
            switch display.phase {
            case .waiting:
                row(title: L("ask.plugin.waiting"), meta: [], enabled: false)
            case let .ready(plan):
                row(title: plan.title, meta: plan.meta, enabled: true, action: plan.action(for: .enter))
            case let .running(plan):
                card(plan: plan, output: display.partial ?? display.previous, failure: nil, running: true,
                     streaming: display.partial != nil)
            case let .done(plan, output):
                card(plan: plan, output: output, failure: nil, running: false)
            case let .failed(plan, failure):
                card(plan: plan, output: nil, failure: failure, running: false)
            }
        }
    }

    private var highlighted: Bool { display.highlighted == 0 }

    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func metaChips(_ meta: [AskPluginMeta]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(meta.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                Text(item.text).font(.system(size: 12))
                    .foregroundStyle(item.emphasized ? AskTheme.accent : StudioTheme.textPrimary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background((item.emphasized ? AskTheme.accent.opacity(0.16) : AskTheme.hoverFill),
                                in: Capsule())
            }
        }
        .fixedSize()
    }

    /// Waiting for input, or ready to run on Return.
    private func row(title: String, meta: [AskPluginMeta], enabled: Bool, action: AskPluginAction? = nil) -> some View {
        Button(action: onMain) {
            HStack(spacing: 12) {
                tile(display.symbol).opacity(enabled ? 1 : 0.45)
                Text(title).font(.system(size: 13.5))
                    .foregroundStyle(enabled ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                    .lineLimit(1)
                metaChips(meta)
                Spacer(minLength: 8)
                if enabled {
                    Text(action.map { $0.title + "  ↩" } ?? "↩").font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(highlighted && enabled ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if highlighted, enabled {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AskTheme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier("ask.plugin.row")
    }

    private func hintRow(_ hint: AskKeyword) -> some View {
        Button(action: onMain) {
            HStack(spacing: 12) {
                tile(display.symbol)
                Text(display.title).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary)
                Text(hint.keyword).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(StudioTheme.textTertiary)
                Spacer(minLength: 8)
                Text(L("ask.plugin.enter")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.askHeight)
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(display.title)
        .accessibilityHint(L("ask.plugin.enter"))
        .accessibilityIdentifier("ask.plugin.hint")
    }

    /// A result, the previous one dimmed while the next runs, or what went wrong.
    private func card(plan: AskPluginPlan, output: AskPluginOutput?, failure: AskPluginFailure?, running: Bool,
                      streaming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(plan.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                metaChips(output?.meta ?? plan.meta)
                Spacer(minLength: 8)
                if let output {
                    Text(output.source).font(.system(size: 11))
                        .foregroundStyle(output.sourceIsAI ? AskTheme.accent : StudioTheme.textTertiary)
                        .padding(.horizontal, 6).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AskTheme.separator))
                }
            }
            .frame(height: Self.headerHeight)
            .padding(.bottom, 8)
            if let output, let card = output.wordCard {
                AskWordCardView(card: card, language: Self.spokenLanguage(output) ?? "en", dimmed: running,
                                onAction: onAction)
                if let note = output.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(height: Self.noteHeight).padding(.top, 6)
                }
                actions(output.actions, enabled: !running)
            } else if let output {
                if display.comparing {
                    ScrollView(.vertical) {
                        Text(output.original).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: Self.originalHeight(output.original))
                    Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.vertical, 4)
                }
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        // A streaming result is bright with a caret; an old one waiting for its successor is dim.
                        Text(streaming ? output.body + Self.caret : output.body)
                            .font(Font(Self.bodyFont)).lineSpacing(Self.bodyLineSpacing)
                            .foregroundStyle(running && !streaming ? StudioTheme.textTertiary : StudioTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(Self.bodyID)
                    }
                    // Long streams keep their newest line in view.
                    .onChange(of: output.body) { _ in if streaming { reader.scrollTo(Self.bodyID, anchor: .bottom) } }
                }
                .frame(height: Self.bodyHeight(output.body))
                if let note = output.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(height: Self.noteHeight).padding(.top, 6)
                }
                actions(output.actions, enabled: !running)
            } else if let failure {
                Text(failure.message).font(.system(size: 13.5)).foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if failure.retry || !failure.actions.isEmpty {
                    HStack(spacing: 6) {
                        Spacer()
                        ForEach(Array(failure.actions.enumerated()), id: \.offset) { _, action in
                            actionButton(title: action.title, symbol: action.symbol, key: Self.key(action.shortcut),
                                         primary: false) { onAction(action) }
                        }
                        if failure.retry {
                            actionButton(title: L("ask.plugin.action.retry"), symbol: "arrow.clockwise", key: "↩",
                                         primary: true, action: onMain)
                        }
                    }
                    .frame(height: Self.actionsHeight)
                    .padding(.top, 10)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6).fill(AskTheme.hoverFill).frame(height: 14)
                    RoundedRectangle(cornerRadius: 6).fill(AskTheme.hoverFill).frame(width: Self.textWidth * 0.6, height: 14)
                }
                .frame(height: Self.skeletonHeight, alignment: .top)
                .accessibilityLabel(L("ask.plugin.running"))
            }
        }
        .padding(Self.cardPadding)
        .background(highlighted ? AskTheme.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(highlighted ? AskTheme.accent.opacity(0.55) : AskTheme.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.plugin.card")
    }

    private func actions(_ actions: [AskPluginAction], enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            // ⌘E (edit the workflow) works from the keyboard without taking room in the row.
            ForEach(Array(actions.filter {
                switch $0.kind {
                case .askAI, .editWorkflow: false
                default: true
                }
            }.enumerated()),
                    id: \.offset) { _, action in
                actionButton(title: action.title, symbol: action.symbol, key: Self.key(action.shortcut),
                             primary: action.shortcut == .enter) { onAction(action) }
            }
        }
        .frame(height: Self.actionsHeight)
        .padding(.top, 10)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    /// The language the result's read-aloud action uses.
    static func spokenLanguage(_ output: AskPluginOutput) -> String? {
        output.actions.lazy.compactMap { action -> String? in
            if case let .speak(_, language) = action.kind { language } else { nil }
        }.first
    }

    static func key(_ shortcut: AskPluginAction.Shortcut?) -> String? {
        switch shortcut {
        case .enter: "↩"
        case .optionEnter: "⌥↩"
        case .commandR: "⌘R"
        case .commandD: "⌘D"
        case .commandC: "⌘C"
        case .shiftCommandC: "⇧⌘C"
        case .commandE: "⌘E"
        case nil: nil
        }
    }

    private func actionButton(title: String, symbol: String, key: String?, primary: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 11.5))
                if let key { Text(key).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary) }
            }
            .foregroundStyle(primary ? AskTheme.accent : StudioTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.actionsHeight)
            .background(primary ? AskTheme.accent.opacity(0.16) : AskTheme.hoverFill,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var askRow: some View {
        Button(action: onAskAI) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AskTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(L("ask.quick.askAI")).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary)
                if !question.isEmpty {
                    Text("“" + question + "”").font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(display.asksAI ? "↩" : "⌘↩").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.askHeight)
            .background(display.asksAI ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ask.quick.askAI"))
        .accessibilityAddTraits(display.asksAI ? .isSelected : [])
        .accessibilityIdentifier("ask.plugin.askAI")
    }
}
