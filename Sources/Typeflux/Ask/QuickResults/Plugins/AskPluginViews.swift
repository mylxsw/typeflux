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
    /// False when there is nothing to ask about (no text, selection or result to
    /// ask on): the "Ask AI" row is left out rather than shown empty.
    var offersAskAI = true

    var output: AskPluginOutput? { if case let .done(_, output) = phase { output } else { nil } }
    var asksAI: Bool { offersAskAI && highlighted == 1 }

    /// Whether "Ask AI" has something to ask: typed text, a selection the plugin
    /// works on, or a result that offers asking about itself.
    static func offersAskAI(question: String, selection: String?, usesSelection: Bool,
                            output: AskPluginOutput?) -> Bool {
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if usesSelection, let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return output?.askAIAction != nil
    }
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

/// The results area in keyword mode: a plugin row, flat list or result card, then "Ask AI".
struct AskPluginResultsView: View {
    @State private var pointer = AskSearchPointer(position: NSEvent.mouseLocation)
    var display: AskPluginDisplay
    var question: String
    var minimumHeight: CGFloat = 0
    /// Return on the plugin's row: run, or the result's main action.
    var onMain: () -> Void
    var onAction: (AskPluginAction) -> Void
    var onAskAI: () -> Void
    var onHighlight: (Int) -> Void
    /// A click on a list's row chooses it (then Return's action runs).
    var onSelectItem: (Int) -> Void = { _ in }

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
    static let itemHeight: CGFloat = 44
    static let itemSpacing: CGFloat = 2
    /// Longer lists scroll; the launcher does not grow past this many rows.
    static let maximumVisibleItems = 6
    /// Only completed lists offer numbered choices; stale lists shown while running do not.
    static func numberedItemCount(_ display: AskPluginDisplay) -> Int? {
        guard display.hint == nil, case let .done(_, output) = display.phase,
              output.wordCard == nil, !output.items.isEmpty else { return nil }
        return output.items.count
    }
    static let maximumMarkdownHeight: CGFloat = 280
    static let maximumImageHeight: CGFloat = 240
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

    /// The rows a list shows at once, and their spacing.
    static func itemsHeight(_ count: Int) -> CGFloat {
        let visible = CGFloat(min(max(count, 1), maximumVisibleItems))
        return visible * itemHeight + (visible - 1) * itemSpacing
    }

    /// Heights already measured: the launcher asks for the same text's height several times per update.
    private static let markdownHeights: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 16
        return cache
    }()

    /// Markdown drawn as Ask draws answers, measured at the card's width.
    static func markdownHeight(_ text: String) -> CGFloat {
        if let known = markdownHeights.object(forKey: text as NSString) { return CGFloat(known.doubleValue) }
        let height = measureMarkdown(text)
        markdownHeights.setObject(NSNumber(value: Double(height)), forKey: text as NSString)
        return height
    }

    private static func measureMarkdown(_ text: String) -> CGFloat {
        let storage = NSTextStorage(attributedString: AskMarkdownText.render(text))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return min(maximumMarkdownHeight, max(22, ceil(layout.usedRect(for: container).height)))
    }

    /// The result's height: a flat list, or a card with header, text (and the
    /// original when comparing), a note and actions.
    static func cardHeight(output: AskPluginOutput?, failure: AskPluginFailure?, comparing: Bool) -> CGFloat {
        if let output, output.wordCard == nil, !output.items.isEmpty {
            return itemsHeight(output.items.count) + (output.note != nil ? 12 + noteHeight : 0)
        }
        var height = cardPadding.top + headerHeight + 8 + cardPadding.bottom
        if let output, let card = output.wordCard {
            height += AskWordCardView.height(card)
            if output.note != nil { height += 6 + noteHeight }
            height += 10 + actionsHeight
        } else if let output, let image = output.image {
            height += imageSize(image).height
            if output.note != nil { height += 6 + noteHeight }
            height += 10 + actionsHeight
        } else if let output {
            if comparing { height += originalHeight(output.original) + 9 }
            height += output.markdown ? markdownHeight(output.body) : bodyHeight(output.body)
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
        let ask = display.offersAskAI ? sectionHeight + rowSpacing + rowSpacing + askHeight : 0
        return 1 + listPadding * 2 + sectionHeight + rowSpacing + mainHeight(display) + ask
    }

    /// What Return and the other keys do now, for the bottom bar.
    static func hint(for display: AskPluginDisplay) -> String {
        // The chat button already names this action in the bottom bar.
        if display.hint?.pluginID == AskOpenChatPlugin.id {
            return display.asksAI ? L("ask.launcher.hint") : ""
        }
        // The highlighted row is what Return does; the bar says the same.
        if display.hint != nil {
            return display.asksAI ? L("ask.plugin.hint.keyword") : L("ask.plugin.hint.keyword.enter")
        }
        if display.asksAI { return L("ask.launcher.hint") }
        let option = display.optionName.map { L("ask.plugin.hint.option", $0) }
        let askAI = display.offersAskAI ? L("ask.plugin.hint.askAI") : nil
        let parts: [String?]
        switch display.phase {
        // Esc always closes the launcher; the bar spends its room on other keys.
        case .waiting: return ""
        case let .ready(plan):
            if let action = plan.action(for: .enter) {
                if case .openChat = action.kind { return "" }
                parts = [L("ask.plugin.hint.action", action.title),
                         plan.action(for: .commandC).map { L("ask.plugin.hint.copy", $0.title) },
                         option, askAI]
            } else {
                parts = [L("ask.plugin.hint.ready"), option]
            }
        case .running: return L("ask.plugin.hint.running")
        case let .done(_, output) where !output.items.isEmpty:
            // A list: what the chosen row's keys do.
            parts = [output.action(for: .enter).map { L("ask.plugin.hint.action", $0.title) },
                     output.action(for: .optionEnter).map { L("ask.plugin.hint.option.enter", $0.title) },
                     output.selected?.autocomplete.map { _ in L("ask.plugin.hint.complete") },
                     askAI]
        case let .done(_, output):
            // Without a main action Return does nothing, so the bar leaves it out.
            let main = output.action(for: .enter)?.title
            let keys = main.map { main in
                output.action(for: .optionEnter).map { L("ask.plugin.hint.done", main, $0.title) }
                    ?? L("ask.plugin.hint.action", main)
            }
            parts = [keys, option, askAI]
        case let .failed(_, failure): return failure.retry ? L("ask.plugin.hint.failed") : ""
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: Self.rowSpacing) {
                section(Self.sectionTitle(for: display))
                main
                    .onContinuousHover { phase in
                        if case .active = phase, pointer.moved(to: NSEvent.mouseLocation) { onHighlight(0) }
                    }
                if display.offersAskAI {
                    section(L("ask.quick.section.ai"))
                    askRow
                        .modifier(AskLauncherNumberBadge(number: Self.numberedItemCount(display)
                            .flatMap { AskLauncherNumberShortcuts.number(at: $0) }))
                        .onContinuousHover { phase in
                            if case .active = phase, pointer.moved(to: NSEvent.mouseLocation) { onHighlight(1) }
                        }
                }
            }
            .padding(Self.listPadding)
            Spacer(minLength: 0)
        }
        .frame(height: max(minimumHeight, Self.height(for: display)), alignment: .top)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Self.sectionHeight, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
    }

    /// Lists use their plan's heading once, without repeating the plugin and source.
    static func sectionTitle(for display: AskPluginDisplay) -> String {
        if display.hint != nil { return L("ask.plugin.section") }
        switch display.phase {
        case let .done(plan, output) where output.wordCard == nil && !output.items.isEmpty:
            return plan.title
        case let .running(plan):
            if let output = display.partial ?? display.previous, output.wordCard == nil, !output.items.isEmpty {
                return plan.title
            }
        default: break
        }
        return display.title
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

    /// What enters the offered keyword: Return when its row is highlighted, otherwise space or ⇥.
    static func hintRowKeys(_ hint: AskKeyword, highlighted: Bool) -> String {
        if hint.pluginID == AskOpenChatPlugin.id { return "↩" }
        return highlighted ? L("ask.plugin.enter.return") : L("ask.plugin.enter")
    }

    static func rowHint(for action: AskPluginAction?) -> String {
        if case .openChat? = action?.kind { return "↩" }
        return action.map { $0.title + "  ↩" } ?? "↩"
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
                    Text(Self.rowHint(for: action)).font(.system(size: 11.5))
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
                Text(Self.hintRowKeys(hint, highlighted: highlighted))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.askHeight)
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(display.title)
        .accessibilityHint(hint.pluginID == AskOpenChatPlugin.id ? L("ask.plugin.hint.action", display.title) : L("ask.plugin.enter"))
        .accessibilityIdentifier("ask.plugin.hint")
    }

    /// A result, the previous one dimmed while the next runs, or what went wrong.
    @ViewBuilder
    private func card(plan: AskPluginPlan, output: AskPluginOutput?, failure: AskPluginFailure?, running: Bool,
                      streaming: Bool = false) -> some View {
        if let output, output.wordCard == nil, !output.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                itemList(output, dimmed: running)
                if let note = output.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.noteHeight)
                        .padding(.horizontal, 10).padding(.top, 12)
                }
            }
        } else {
            resultCard(plan: plan, output: output, failure: failure, running: running, streaming: streaming)
        }
    }

    private func resultCard(plan: AskPluginPlan, output: AskPluginOutput?, failure: AskPluginFailure?, running: Bool,
                            streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(plan.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                metaChips(output?.meta ?? plan.meta)
                Spacer(minLength: 8)
                if let output {
                    if let detail = output.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                    Text(output.source).font(.system(size: 11))
                        .foregroundStyle(output.sourceIsAI ? AskTheme.accent : StudioTheme.textTertiary)
                        .padding(.horizontal, 6).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AskTheme.separator))
                    headerButtons(output, enabled: !running)
                }
            }
            .frame(height: Self.headerHeight)
            .padding(.bottom, 8)
            if let output {
                result(output, running: running, streaming: streaming)
                if let note = output.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(height: Self.noteHeight).padding(.top, 6)
                }
                // A list has no button row: the bottom bar says what the chosen row's keys do.
                if output.items.isEmpty {
                    actions(output.actions, enabled: !running)
                }
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

    /// The result itself: a word card, a list, Markdown, or text (under the original when comparing).
    @ViewBuilder
    private func result(_ output: AskPluginOutput, running: Bool, streaming: Bool) -> some View {
        if let card = output.wordCard {
            AskWordCardView(card: card, language: Self.spokenLanguage(output) ?? "en", dimmed: running,
                            onAction: onAction)
        } else if !output.items.isEmpty {
            itemList(output, dimmed: running)
        } else if let image = output.image {
            imageCard(image, dimmed: running)
        } else if output.markdown {
            ScrollView(.vertical) {
                AskTranscriptText(text: streaming ? output.body + Self.caret : output.body)
                    .opacity(running && !streaming ? 0.5 : 1)
            }
            .frame(height: Self.markdownHeight(output.body))
        } else {
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
        }
    }

    /// Result rows: icon, title and subtitle; the chosen one says what Return does.
    private func itemList(_ output: AskPluginOutput, dimmed: Bool) -> some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(spacing: Self.itemSpacing) {
                    ForEach(Array(output.items.enumerated()), id: \.element.id) { index, item in
                        AskPluginItemRow(item: item, symbol: display.symbol, selected: index == output.selectedItem,
                                         emphasized: highlighted, height: Self.itemHeight) {
                            onSelectItem(index)
                            onMain()
                        }
                        .modifier(AskLauncherNumberBadge(number: Self.numberedItemCount(display) == nil
                            ? nil : AskLauncherNumberShortcuts.number(at: index)))
                        .id(item.id)
                    }
                }
            }
            .scrollDisabled(output.items.count <= Self.maximumVisibleItems)
            .onChange(of: output.selected?.id) { id in
                if let id { reader.scrollTo(id) }
            }
        }
        .frame(height: Self.itemsHeight(output.items.count))
        .opacity(dimmed ? 0.5 : 1)
        .disabled(dimmed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.plugin.items")
    }

    private func actions(_ actions: [AskPluginAction], enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            // ⌘E (edit the workflow) works from the keyboard without taking room in the row;
            // the star sits in the header.
            ForEach(Array(actions.filter {
                switch $0.kind {
                case .askAI, .editWorkflow, .toggleStar, .openWordBook: false
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

    /// Small buttons beside the source label: the word book's star (⌘S) and the word book itself (⌘B).
    @ViewBuilder
    private func headerButtons(_ output: AskPluginOutput, enabled: Bool) -> some View {
        if let book = output.actions.first(where: { if case .openWordBook = $0.kind { true } else { false } }) {
            Button { onAction(book) } label: {
                Image(systemName: "character.book.closed").font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 22, height: 20)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(book.title + " ⌘B")
            .accessibilityLabel(book.title)
            .accessibilityIdentifier("ask.plugin.wordBook")
            .disabled(!enabled)
        }
        if let star = output.actions.first(where: { if case .toggleStar = $0.kind { true } else { false } }) {
            let starred = output.starred == true
            Button { onAction(star) } label: {
                Image(systemName: starred ? "star.fill" : "star").font(.system(size: 12))
                    .foregroundStyle(starred ? Color.yellow : StudioTheme.textSecondary)
                    .frame(width: 22, height: 20)
                    .background(starred ? Color.yellow.opacity(0.16) : AskTheme.hoverFill,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(star.title + " ⌘S")
            .accessibilityLabel(star.title)
            .accessibilityIdentifier("ask.plugin.star")
            .disabled(!enabled)
        }
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
        case .commandS: "⌘S"
        case .commandB: "⌘B"
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

/// A workflow's image result (`display: image`).
extension AskPluginResultsView {
    /// An image's size in the card: as it is, or scaled down to fit the card's width
    /// and `maximumImageHeight`; never enlarged.
    static func imageSize(_ image: AskPluginImage) -> CGSize {
        let scale = min(1, Double(textWidth) / image.width, Double(maximumImageHeight) / image.height)
        return CGSize(width: max(1, (image.width * scale).rounded()), height: max(1, (image.height * scale).rounded()))
    }

    /// Images already read, so redrawing the launcher does not read the file again. A
    /// script that writes the same file each run gets its new picture: the key has the date.
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    static func loadImage(_ url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = (url.path + "|" + String(modified?.timeIntervalSinceReferenceDate ?? 0)) as NSString
        if let known = images.object(forKey: key) { return known }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// A workflow's image, at its own size or scaled down to fit, centred.
    private func imageCard(_ image: AskPluginImage, dimmed: Bool) -> some View {
        let size = Self.imageSize(image)
        return Group {
            if let picture = Self.loadImage(image.url) {
                Image(nsImage: picture).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: size.height, maxHeight: size.height)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement()
        .accessibilityLabel(image.url.lastPathComponent)
        .accessibilityIdentifier("ask.plugin.image")
    }
}
