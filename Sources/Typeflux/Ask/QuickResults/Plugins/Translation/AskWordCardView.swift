// swiftlint:disable file_length
import AppKit
import SwiftUI

/// A word card inside the translation result: the target-language equivalent,
/// the source word and how it sounds, its
/// meanings by part of speech (each one copies on click), forms, examples and
/// synonyms. Its height is worked out from the text, so the launcher can size
/// itself before the card is drawn; past `maximumHeight` it scrolls.
struct AskWordCardView: View {
    var card: AskWordCard
    /// The word's language, for reading it aloud when a phonetic does not say which accent.
    var language: String
    var dimmed = false
    var stackStyle = false
    var onAction: (AskPluginAction) -> Void
    @State private var expandedExamples = false

    static let maximumHeight: CGFloat = 300
    static let headwordHeight: CGFloat = 30
    static let translatedWordFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let posWidth: CGFloat = 44
    /// The translation panel's label column: parts of speech, forms, examples and synonyms line up in it.
    static let stackLabelWidth: CGFloat = 38
    static let stackLabelSpacing: CGFloat = 8
    static let stackHeadwordHeight: CGFloat = 32
    static let stackPhoneticHeight: CGFloat = 26
    static let synonymHeight: CGFloat = 24
    static let senseSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 10
    static let meaningFont = NSFont.systemFont(ofSize: 14.5)
    static let detailFont = NSFont.systemFont(ofSize: 11.5)
    static let exampleFont = NSFont.systemFont(ofSize: 13)
    static let translationFont = NSFont.systemFont(ofSize: 12.5)
    static let labelHeight: CGFloat = 16
    static let exampleInset: CGFloat = 10
    private static let meaningScheme = "typeflux-meaning"

    private static var width: CGFloat {
        AskPluginResultsView.textWidth
    }

    private static var meaningWidth: CGFloat {
        width - posWidth - 10
    }

    private static var stackColumnWidth: CGFloat {
        width - stackLabelWidth - stackLabelSpacing
    }

    static func meaningsText(_ sense: AskWordCard.Sense) -> String {
        sense.meanings.joined(separator: AskWordCard.meaningSeparator)
    }

    static func formsText(_ card: AskWordCard) -> String {
        card.forms.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }

    static func synonymsText(_ card: AskWordCard) -> String {
        L("ask.plugin.wordCard.synonyms") + "  " + card.synonyms.joined(separator: " · ")
    }

    /// `**word**` marks the word in an example; drawn bold, measured without the marks.
    static func plain(_ example: String) -> String {
        example.replacingOccurrences(of: "**", with: "")
    }

    /// The card's full height before any scrolling.
    static func contentHeight(_ card: AskWordCard, expandedExamples: Bool = false, stackStyle: Bool = false) -> CGFloat {
        if stackStyle {
            return stackContentHeight(card, expandedExamples: expandedExamples)
        }
        let text = AskPluginResultsView.textHeight
        var height = headwordHeight
        if let translation = card.translatedText {
            height += max(headwordHeight, text(translation, translatedWordFont, 0, width)) + 4
        }
        height += card.senses.reduce(0) { total, sense in
            total + senseSpacing + max(20, text(meaningsText(sense), meaningFont, 2, meaningWidth))
        }
        if !card.forms.isEmpty {
            height += 8 + text(formsText(card), detailFont, 0, width)
        }
        if !card.examples.isEmpty {
            height += sectionSpacing + 1 + 8 + labelHeight
            height += visibleExamples(card, expanded: expandedExamples).reduce(0) { total, example in
                total + 8 + text(plain(example.source), exampleFont, 0, width - exampleInset)
                    + (example.target.isEmpty ? 0 : 2 + text(plain(example.target), translationFont, 0,
                                                             width - exampleInset))
            }
            if card.examples.count > 2, !expandedExamples {
                height += 24
            }
        }
        if !card.synonyms.isEmpty {
            height += sectionSpacing + text(synonymsText(card), detailFont, 0, width)
        }
        return ceil(height)
    }

    static func height(_ card: AskWordCard, stackStyle: Bool = false, expandedExamples: Bool = false) -> CGFloat {
        // The translation stack scrolls as a whole, so its cards keep their full height.
        stackStyle ? contentHeight(card, expandedExamples: expandedExamples, stackStyle: true)
            : min(maximumHeight, contentHeight(card, expandedExamples: expandedExamples))
    }

    var body: some View {
        Group {
            if stackStyle {
                contents
            } else {
                ScrollView(.vertical) { contents }
                    .frame(height: Self.height(card, expandedExamples: expandedExamples))
            }
        }
        .onChange(of: card) { _ in expandedExamples = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.plugin.wordCard")
    }

    private var contents: some View {
        Group {
            if stackStyle {
                stackContents
            } else {
                launcherContents
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }

    private var launcherContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let translation = card.translatedText {
                Text(translation)
                    .font(Font(Self.translatedWordFont))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("ask.plugin.wordCard.translation")
                    .padding(.bottom, 4)
            }
            headword
            ForEach(Array(card.senses.enumerated()), id: \.offset) { index, sense in
                senseRow(sense, first: index == 0)
                    .padding(.top, Self.senseSpacing)
            }
            if !card.forms.isEmpty {
                Text(Self.formsText(card)).font(Font(Self.detailFont)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            if !card.examples.isEmpty {
                examples
            }
            if !card.synonyms.isEmpty {
                Text(Self.synonymsText(card)).font(Font(Self.detailFont)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Self.sectionSpacing)
                    .textSelection(.enabled)
            }
        }
    }

    private var headword: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(card.headword).font(.system(size: card.translatedText == nil ? 22 : 13,
                                             weight: card.translatedText == nil ? .semibold : .regular))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            HStack(spacing: 12) {
                ForEach(Array(card.phonetics.enumerated()), id: \.offset) { index, phonetic in
                    HStack(spacing: 4) {
                        Text(phonetic.label).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                        Text(phonetic.text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1)
                        Button {
                            onAction(AskPluginAction(
                                kind: .speak(card.headword, language: Self.voice(for: phonetic, default: language)),
                                title: L("ask.plugin.action.speak"),
                                symbol: "speaker.wave.2",
                                shortcut: nil
                            ))
                        } label: {
                            Image(systemName: "speaker.wave.2").font(.system(size: 10))
                                .frame(width: 20, height: 20)
                                .background(
                                    AskTheme.hoverFill,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary)
                        .accessibilityLabel(L("ask.plugin.action.speak") + " " + phonetic.label)
                        .accessibilityIdentifier("ask.plugin.wordCard.phonetic.\(index)")
                    }
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.headwordHeight, alignment: .leading)
    }

    private func senseRow(_ sense: AskWordCard.Sense, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: stackStyle ? Self.stackLabelSpacing : 10) {
            Text(sense.pos).font(.system(size: stackStyle ? 12.5 : 11.5, weight: stackStyle ? .semibold : .bold))
                .italic()
                .foregroundStyle(stackStyle ? StudioTheme.textTertiary : AskTheme.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: stackStyle ? Self.stackLabelWidth : Self.posWidth, alignment: .trailing)
            Text(meanings(sense, first: first))
                .font(Font(Self.meaningFont)).lineSpacing(2)
                .tint(StudioTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == Self.meaningScheme, let index = Int(url.host ?? ""),
                          sense.meanings.indices.contains(index) else { return .discarded }
                    let meaning = sense.meanings[index]
                    onAction(AskPluginAction(kind: .copy(meaning), title: L("ask.plugin.action.copy"),
                                             symbol: "doc.on.doc", shortcut: nil))
                    return .handled
                })
        }
    }

    /// Each meaning is a link that copies it; the card's first meaning is bold.
    private func meanings(_ sense: AskWordCard.Sense, first: Bool) -> AttributedString {
        var text = AttributedString()
        for (index, meaning) in sense.meanings.enumerated() {
            if index > 0 {
                var separator = AttributedString(AskWordCard.meaningSeparator)
                separator.foregroundColor = StudioTheme.textTertiary
                text += separator
            }
            var part = AttributedString(meaning)
            part.link = URL(string: "\(Self.meaningScheme)://\(index)")
            part.foregroundColor = StudioTheme.textPrimary
            if first, index == 0 {
                part.font = .system(size: 14.5, weight: .semibold)
            }
            text += part
        }
        return text
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            Text(L("ask.plugin.wordCard.examples")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(height: Self.labelHeight, alignment: .bottom)
                .padding(.top, 8)
            ForEach(Array(Self.visibleExamples(card, expanded: expandedExamples).enumerated()),
                    id: \.offset) { index, example in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.emphasized(example.source)).font(Font(Self.exampleFont))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if !example.target.isEmpty {
                        Text(Self.emphasizedTarget(example.target)).font(Font(Self.translationFont))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.exampleInset)
                .overlay(alignment: .leading) { Rectangle().fill(AskTheme.separator).frame(width: 2) }
                .padding(.top, 8)
                .textSelection(.enabled)
                .accessibilityIdentifier("ask.plugin.wordCard.example.\(index)")
            }
            if card.examples.count > 2, !expandedExamples {
                moreExamplesButton.padding(.top, 4)
            }
        }
        .padding(.top, Self.sectionSpacing)
    }
}

// MARK: Translation panel layout

extension AskWordCardView {
    private var moreExamplesButton: some View {
        Button(L("ask.plugin.wordCard.moreExamples", card.examples.count - 2)) { expandedExamples = true }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AskTheme.accent)
            .accessibilityIdentifier("ask.plugin.wordCard.moreExamples")
    }

    /// Headword with its brief translation, phonetic capsules, then senses and labelled sections
    /// sharing one label column.
    private var stackContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(card.headword).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                if let translation = card.translatedText {
                    Text(translation).font(.system(size: 15, weight: .semibold)).foregroundStyle(AskTheme.accent)
                        .lineLimit(2).textSelection(.enabled)
                        .accessibilityIdentifier("ask.plugin.wordCard.translation")
                }
            }
            .frame(minHeight: Self.stackHeadwordHeight, alignment: .leading)
            if !card.phonetics.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(card.phonetics.enumerated()), id: \.offset) { index, phonetic in
                        phoneticCapsule(phonetic, index: index)
                    }
                }
                .padding(.top, 6)
            }
            ForEach(Array(card.senses.enumerated()), id: \.offset) { index, sense in
                senseRow(sense, first: index == 0)
                    .padding(.top, index == 0 ? 10 : Self.senseSpacing)
            }
            if !card.forms.isEmpty {
                stackSection(L("ask.plugin.wordCard.forms")) {
                    AskFlowLayout(spacing: 12) {
                        ForEach(Array(card.forms.enumerated()), id: \.offset) { _, form in
                            (Text(form.label + " ").foregroundColor(StudioTheme.textTertiary)
                                + Text(form.value).foregroundColor(StudioTheme.textSecondary))
                                .font(Font(Self.detailFont)).textSelection(.enabled)
                        }
                    }
                }
            }
            if !card.examples.isEmpty {
                stackSection(L("ask.plugin.wordCard.examples")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(Self.visibleExamples(card, expanded: expandedExamples).enumerated()),
                                id: \.offset) { index, example in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.emphasized(example.source)).font(Font(Self.exampleFont))
                                    .foregroundStyle(StudioTheme.textPrimary)
                                if !example.target.isEmpty {
                                    Text(Self.emphasizedTarget(example.target)).font(Font(Self.translationFont))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("ask.plugin.wordCard.example.\(index)")
                        }
                        if card.examples.count > 2, !expandedExamples {
                            moreExamplesButton
                        }
                    }
                }
            }
            if !card.synonyms.isEmpty {
                stackSection(L("ask.plugin.wordCard.synonyms")) {
                    AskFlowLayout(spacing: 5) {
                        ForEach(Array(card.synonyms.enumerated()), id: \.offset) { index, synonym in
                            AskWordCardSynonymButton(word: synonym) {
                                onAction(AskPluginAction(kind: .runWith(synonym), title: synonym,
                                                         symbol: "magnifyingglass", shortcut: nil))
                            }
                            .accessibilityIdentifier("ask.plugin.wordCard.synonym.\(index)")
                        }
                    }
                }
            }
        }
    }

    private func stackSection(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.stackLabelSpacing) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: Self.stackLabelWidth, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, Self.sectionSpacing + 2)
    }

    private func phoneticCapsule(_ phonetic: AskWordCard.Phonetic, index: Int) -> some View {
        Button {
            onAction(AskPluginAction(
                kind: .speak(card.headword, language: Self.voice(for: phonetic, default: language)),
                title: L("ask.plugin.action.speak"),
                symbol: "speaker.wave.2",
                shortcut: nil
            ))
        } label: {
            HStack(spacing: 5) {
                Text(phonetic.label).font(.system(size: 10, weight: .bold)).foregroundStyle(StudioTheme.textTertiary)
                Text(phonetic.text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                Image(systemName: "speaker.wave.2").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.leading, 8).padding(.trailing, 9).frame(height: Self.stackPhoneticHeight)
            .background(AskTheme.hoverFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(L("ask.plugin.action.speak") + " " + phonetic.label)
        .accessibilityIdentifier("ask.plugin.wordCard.phonetic.\(index)")
    }
}

/// A synonym chip; looking it up replaces the original with the synonym.
private struct AskWordCardSynonymButton: View {
    var word: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(word).font(.system(size: 12.5))
                .foregroundStyle(hovering ? AskTheme.accent : StudioTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10).frame(height: AskWordCardView.synonymHeight)
                .background(hovering ? AskTheme.accent.opacity(0.14) : AskTheme.hoverFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(word)
    }
}

extension AskWordCardView {
    /// "UK" and "US" phonetics are read with British and American voices.
    static func voice(for phonetic: AskWordCard.Phonetic, default language: String) -> String {
        let label = phonetic.label.uppercased()
        if label.contains("UK") || label.contains("BR") || phonetic.label.contains("英") {
            return "en-GB"
        }
        if label.contains("US") || label.contains("AM") || phonetic.label.contains("美") {
            return "en-US"
        }
        return language
    }

    static func visibleExamples(_ card: AskWordCard, expanded: Bool) -> [AskWordCard.Example] {
        Array(card.examples.prefix(expanded ? card.examples.count : 2))
    }

    /// The example with its `**word**` in the accent colour, and no asterisks.
    static func emphasized(_ example: String) -> AttributedString {
        marked(example) { run in
            run.foregroundColor = AskTheme.accent
            run.font = .system(size: 13, weight: .semibold)
        }
    }

    /// The example's translation with its `**word**` in primary text, and no asterisks.
    static func emphasizedTarget(_ translation: String) -> AttributedString {
        marked(translation) { run in
            run.foregroundColor = StudioTheme.textPrimary
            run.font = .system(size: 12.5, weight: .semibold)
        }
    }

    private static func marked(_ text: String, style: (inout AttributedString) -> Void) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: "**").enumerated() {
            var run = AttributedString(part)
            if index.isMultiple(of: 2) == false {
                style(&run)
            }
            result += run
        }
        return result
    }

    /// The translation panel card's height, measured the way `stackContents` lays it out.
    static func stackContentHeight(_ card: AskWordCard, expandedExamples: Bool = false) -> CGFloat {
        let text = AskPluginResultsView.textHeight
        let column = stackColumnWidth
        var height = stackHeadwordHeight
        if !card.phonetics.isEmpty {
            height += 6 + stackPhoneticHeight
        }
        for (index, sense) in card.senses.enumerated() {
            height += (index == 0 ? 10 : senseSpacing) + max(20, text(meaningsText(sense), meaningFont, 2, column))
        }
        if !card.forms.isEmpty {
            height += sectionSpacing + 2 + text(formsText(card), detailFont, 0, column)
        }
        if !card.examples.isEmpty {
            height += sectionSpacing + 2
            let shown = visibleExamples(card, expanded: expandedExamples)
            height += shown.enumerated().reduce(0) { total, item in
                let example = item.element
                return total + (item.offset == 0 ? 0 : 8) + text(plain(example.source), exampleFont, 0, column)
                    + (example.target.isEmpty ? 0 : 2 + text(plain(example.target), translationFont, 0, column))
            }
            if card.examples.count > 2, !expandedExamples {
                height += 8 + 16
            }
        }
        if !card.synonyms.isEmpty {
            let font = NSFont.systemFont(ofSize: 12.5)
            var rows: CGFloat = 1, line: CGFloat = 0
            for synonym in card.synonyms {
                let item = ceil((synonym as NSString).size(withAttributes: [.font: font]).width) + 20
                if line > 0, line + 5 + item > column {
                    rows += 1
                    line = item
                } else {
                    line += (line > 0 ? 5 : 0) + item
                }
            }
            height += sectionSpacing + 2 + rows * synonymHeight + (rows - 1) * 5
        }
        return ceil(height)
    }
}
