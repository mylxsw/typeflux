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
    var onAction: (AskPluginAction) -> Void

    static let maximumHeight: CGFloat = 300
    static let headwordHeight: CGFloat = 30
    static let translatedWordFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let posWidth: CGFloat = 44
    static let senseSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 10
    static let meaningFont = NSFont.systemFont(ofSize: 14.5)
    static let detailFont = NSFont.systemFont(ofSize: 11.5)
    static let exampleFont = NSFont.systemFont(ofSize: 13)
    static let translationFont = NSFont.systemFont(ofSize: 12.5)
    static let labelHeight: CGFloat = 16
    static let exampleInset: CGFloat = 10
    private static let meaningScheme = "typeflux-meaning"

    private static var width: CGFloat { AskPluginResultsView.textWidth }
    private static var meaningWidth: CGFloat { width - posWidth - 10 }

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
    static func plain(_ example: String) -> String { example.replacingOccurrences(of: "**", with: "") }

    /// The card's full height before any scrolling.
    static func contentHeight(_ card: AskWordCard) -> CGFloat {
        let text = AskPluginResultsView.textHeight
        var height = headwordHeight
        if let translation = card.translatedText {
            height += max(headwordHeight, text(translation, translatedWordFont, 0, width)) + 4
        }
        height += card.senses.reduce(0) { total, sense in
            total + senseSpacing + max(20, text(meaningsText(sense), meaningFont, 2, meaningWidth))
        }
        if !card.forms.isEmpty { height += 8 + text(formsText(card), detailFont, 0, width) }
        if !card.examples.isEmpty {
            height += sectionSpacing + 1 + 8 + labelHeight
            height += card.examples.reduce(0) { total, example in
                total + 8 + text(plain(example.source), exampleFont, 0, width - exampleInset)
                    + (example.target.isEmpty ? 0 : 2 + text(example.target, translationFont, 0, width - exampleInset))
            }
        }
        if !card.synonyms.isEmpty { height += sectionSpacing + text(synonymsText(card), detailFont, 0, width) }
        return ceil(height)
    }

    static func height(_ card: AskWordCard) -> CGFloat { min(maximumHeight, contentHeight(card)) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let translation = card.translatedText {
                    Text(translation).font(Font(Self.translatedWordFont)).foregroundStyle(StudioTheme.textPrimary)
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
                if !card.examples.isEmpty { examples }
                if !card.synonyms.isEmpty {
                    Text(Self.synonymsText(card)).font(Font(Self.detailFont)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Self.sectionSpacing)
                        .textSelection(.enabled)
                }
            }
            .opacity(dimmed ? 0.5 : 1)
        }
        .frame(height: Self.height(card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.plugin.wordCard")
    }

    private var headword: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(card.headword).font(.system(size: card.translatedText == nil ? 22 : 13,
                                            weight: card.translatedText == nil ? .semibold : .regular))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled)
            ForEach(Array(card.phonetics.enumerated()), id: \.offset) { _, phonetic in
                HStack(spacing: 4) {
                    Text(phonetic.label).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                    Text(phonetic.text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                    Button {
                        onAction(AskPluginAction(kind: .speak(card.headword, language: Self.voice(for: phonetic, default: language)),
                                                 title: L("ask.plugin.action.speak"), symbol: "speaker.wave.2", shortcut: nil))
                    } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 10))
                            .frame(width: 20, height: 20)
                            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .accessibilityLabel(L("ask.plugin.action.speak") + " " + phonetic.label)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.headwordHeight)
    }

    /// "UK" and "US" phonetics are read with British and American voices.
    static func voice(for phonetic: AskWordCard.Phonetic, default language: String) -> String {
        let label = phonetic.label.uppercased()
        if label.contains("UK") || label.contains("BR") || phonetic.label.contains("英") { return "en-GB" }
        if label.contains("US") || label.contains("AM") || phonetic.label.contains("美") { return "en-US" }
        return language
    }

    private func senseRow(_ sense: AskWordCard.Sense, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(sense.pos).font(.system(size: 11.5, weight: .bold)).italic()
                .foregroundStyle(AskTheme.accent)
                .frame(width: Self.posWidth, alignment: .trailing)
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
            if first, index == 0 { part.font = .system(size: 14.5, weight: .semibold) }
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
            ForEach(Array(card.examples.enumerated()), id: \.offset) { _, example in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.emphasized(example.source)).font(Font(Self.exampleFont))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if !example.target.isEmpty {
                        Text(example.target).font(Font(Self.translationFont)).foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.exampleInset)
                .overlay(alignment: .leading) { Rectangle().fill(AskTheme.separator).frame(width: 2) }
                .padding(.top, 8)
                .textSelection(.enabled)
            }
        }
        .padding(.top, Self.sectionSpacing)
    }

    /// The example with its `**word**` in the accent colour, and no asterisks.
    static func emphasized(_ example: String) -> AttributedString {
        var text = AttributedString()
        for (index, part) in example.components(separatedBy: "**").enumerated() {
            var run = AttributedString(part)
            if index.isMultiple(of: 2) == false {
                run.foregroundColor = AskTheme.accent
                run.font = .system(size: 13, weight: .semibold)
            }
            text += run
        }
        return text
    }
}
