import SwiftUI

/// Solid reading content; the window toolbar owns actions for the displayed word.
struct AskWordBookDetail: View {
    @ObservedObject var model: AskWordBookViewModel
    var entry: AskWordBookEntry
    var regenerate: (AskWordBookEntry) -> Void

    private var format: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .shortened) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        hero(compact: geometry.size.width < 520)
                        meta
                    }
                    .padding(.bottom, 18)
                    Rectangle().fill(TypefluxColor.separator.color).frame(height: 0.5)
                    if let card = entry.lookup.card {
                        senses(card)
                        if !card.examples.isEmpty { examples(card) }
                        if !card.synonyms.isEmpty || !card.forms.isEmpty { related(card) }
                    } else {
                        plain
                    }
                    if !model.isTransient(entry) { history }
                }
                .frame(maxWidth: AskLibraryLayout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, geometry.size.width < 520 ? 18 : 36)
                .padding(.top, 24).padding(.bottom, 24)
            }
        }
        .accessibilityIdentifier("ask.wordBook.detail")
    }

    private var meta: some View {
        AskWordBookFlow(spacing: 6) {
            Text(AskWordBookViewModel.pairTitle(AskWordBookLanguagePair(source: entry.lookup.source,
                                                                       target: entry.lookup.target),
                                                in: model.interfaceLanguage()))
                .font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
            if model.isTransient(entry) {
                badge(L("ask.wordBook.badge.loose"))
            } else if model.freshKey == entry.key {
                badge(L("ask.wordBook.badge.new"), accent: true)
            } else {
                badge(L("ask.wordBook.badge.count", entry.lookupCount))
            }
            badge(entry.lookup.card != nil
                ? L("ask.wordBook.cardBy", entry.lookup.model ?? "AI") : L("ask.wordBook.plain"))
        }
    }

    private func badge(_ text: String, accent: Bool = false) -> some View {
        TypefluxTag(text, tone: accent ? .accent : .neutral)
    }

    private func hero(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text(entry.headword).font(compact ? .title2 : .title).fontWeight(.bold)
                    .foregroundStyle(TypefluxColor.label.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                AskWordBookFlow(spacing: 6) {
                    if let phonetics = entry.lookup.card?.phonetics, !phonetics.isEmpty {
                        ForEach(Array(phonetics.enumerated()), id: \.offset) { _, phonetic in
                            sound(label: phonetic.label, text: phonetic.text,
                                  language: AskWordCardView.voice(for: phonetic,
                                      default: AskWordBookViewModel.spokenLanguage(entry)))
                        }
                    } else {
                        sound(label: "", text: L("ask.plugin.action.speak"),
                              language: AskWordBookViewModel.spokenLanguage(entry))
                    }
                }
            }
        }
    }

    private func sound(label: String, text: String, language: String) -> some View {
        Button { model.speakText(entry.headword, language) } label: {
            HStack(spacing: 6) {
                if !label.isEmpty { Text(label).font(.caption).foregroundStyle(TypefluxColor.tertiaryLabel.color) }
                Text(text).font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
                Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(L("ask.plugin.action.speak") + " " + label)
    }

    private func senses(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.meanings"), hint: L("ask.wordBook.copyMeaning"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.senses.enumerated()), id: \.offset) { index, sense in
                    if index > 0 { Rectangle().fill(TypefluxColor.separator.color).frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(sense.pos).font(.callout).fontWeight(.semibold).italic()
                            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                            .frame(width: 44, alignment: .leading)
                        AskWordBookFlow(spacing: 4) {
                            ForEach(Array(sense.meanings.enumerated()), id: \.offset) { position, meaning in
                                Button { model.copyText(meaning) } label: {
                                    Text(meaning)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .font(.body).fontWeight(index == 0 && position == 0 ? .semibold : .regular)
                                        .foregroundStyle(TypefluxColor.label.color)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help(L("ask.wordBook.copyMeaning"))
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .background(TypefluxColor.controlBackground.color)
        }
    }

    private func examples(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.plugin.wordCard.examples"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.examples.enumerated()), id: \.offset) { index, example in
                    if index > 0 { Rectangle().fill(TypefluxColor.separator.color).frame(height: 1) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AskWordCardView.emphasized(example.source)).font(.body)
                                .foregroundStyle(TypefluxColor.label.color)
                            if !example.target.isEmpty {
                                Text(example.target).font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
                            }
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            model.speakText(AskWordCardView.plain(example.source),
                                            AskWordBookViewModel.spokenLanguage(entry))
                        } label: {
                            Image(systemName: "speaker.wave.2").font(.callout)
                                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("ask.plugin.action.speak"))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            .background(TypefluxColor.controlBackground.color)
        }
    }

    private func related(_ card: AskWordCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.related"))
            AskWordBookFlow(spacing: 6) {
                ForEach(card.synonyms, id: \.self) { word in relatedWordButton(word, label: nil) }
                ForEach(Array(card.forms.enumerated()), id: \.offset) { _, form in
                    relatedWordButton(form.value, label: form.label)
                }
            }
        }
    }

    private func relatedWordButton(_ word: String, label: String?) -> some View {
        TypefluxButton { Task { await model.lookUp(word) } } label: {
            HStack(spacing: 4) {
                if let label, !label.isEmpty { Text(label).foregroundStyle(.secondary) }
                Text(word).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(L("ask.wordBook.lookUpWord", word))
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.plain"), hint: L("ask.wordBook.copyMeaning"))
            Button { model.copyText(entry.lookup.translation ?? "") } label: {
                Text(entry.lookup.translation ?? "").font(.body).foregroundStyle(TypefluxColor.label.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(TypefluxColor.controlBackground.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.canRegenerate, AskWordCard.isLookup(entry.headword) {
                HStack(spacing: 10) {
                    Text(L("ask.wordBook.plainHint")).font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    Button { regenerate(entry) } label: {
                        Label(L("ask.plugin.action.wordCard"), systemImage: "sparkles").font(.callout)
                            .foregroundStyle(TypefluxColor.label.color)
                            .padding(.horizontal, 10).frame(height: 28)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 10)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWordBookSectionTitle(text: L("ask.wordBook.history"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 0)], alignment: .leading, spacing: 0) {
                fact("ask.wordBook.fact.count", L("ask.wordBook.times", entry.lookupCount))
                fact("ask.wordBook.fact.first", entry.firstLookedUpAt.formatted(format), divided: true)
                fact("ask.wordBook.fact.last", entry.lastLookedUpAt.formatted(format), divided: true)
                if let starred = entry.starredAt {
                    fact("ask.wordBook.fact.starred", starred.formatted(format), divided: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(TypefluxColor.controlBackground.color)
        }
    }

    private func fact(_ label: String, _ value: String, divided: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(label)).font(.caption).foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
            Text(value).font(.callout).fontWeight(.semibold).foregroundStyle(TypefluxColor.label.color)
                .lineLimit(2).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            if divided { Rectangle().fill(TypefluxColor.separator.color).frame(width: 1) }
        }
    }
}
