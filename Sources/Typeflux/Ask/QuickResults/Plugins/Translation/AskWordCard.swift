import Foundation

/// A dictionary entry for a word or short phrase: how it sounds, what it means
/// by part of speech, its forms, examples and near synonyms. The AI writes it
/// when the translation plugin is given a word rather than a sentence.
struct AskWordCard: Codable, Equatable, Sendable {
    struct Phonetic: Codable, Equatable, Sendable {
        /// "UK", "US", "pinyin".
        var label: String
        var text: String
    }

    struct Sense: Codable, Equatable, Sendable {
        /// "n.", "v.", "phr. v.".
        var pos: String
        var meanings: [String]
    }

    struct Form: Codable, Equatable, Sendable {
        /// "plural", "past tense", in the target language.
        var label: String
        var value: String
    }

    struct Example: Codable, Equatable, Sendable {
        /// In the word's language, the word wrapped in `**`.
        var source: String
        var target: String
    }

    var headword: String
    var phonetics: [Phonetic] = []
    var senses: [Sense] = []
    var forms: [Form] = []
    var examples: [Example] = []
    var synonyms: [String] = []

    /// The most common meaning: what ⌥↩ writes in place of the word.
    var firstMeaning: String? { senses.lazy.flatMap(\.meanings).first }

    /// One line for the clipboard: `serendipity /ˌserənˈdɪpəti/ n. 机缘巧合；意外的好运`.
    var summary: String {
        var parts = [headword]
        if let phonetic = phonetics.first { parts.append(phonetic.text) }
        parts += senses.map { sense in
            [sense.pos, sense.meanings.joined(separator: Self.meaningSeparator)].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return parts.joined(separator: " ")
    }

    /// The whole card as Markdown, for ⇧⌘C.
    var markdown: String {
        var lines = ["**\(headword)**" + (phonetics.isEmpty ? "" : " " + phonetics.map { "\($0.label) \($0.text)" }
                .joined(separator: " · "))]
        lines += senses.map { "- *\($0.pos)* " + $0.meanings.joined(separator: Self.meaningSeparator) }
        if !forms.isEmpty { lines.append(forms.map { "\($0.label): \($0.value)" }.joined(separator: " · ")) }
        if !examples.isEmpty {
            lines.append("")
            lines += examples.map { "> \($0.source)\n> \($0.target)" }
        }
        if !synonyms.isEmpty { lines += ["", synonyms.joined(separator: ", ")] }
        return lines.joined(separator: "\n")
    }

    static let meaningSeparator = "；"

    /// Drops empty fields and caps the lists, so a chatty model cannot make the card huge.
    func tidied() -> AskWordCard {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var card = self
        card.headword = clean(headword)
        card.phonetics = phonetics.map { Phonetic(label: clean($0.label), text: clean($0.text)) }
            .filter { !$0.text.isEmpty }.prefix(2).map { $0 }
        card.senses = senses.map { Sense(pos: clean($0.pos), meanings: $0.meanings.map(clean).filter { !$0.isEmpty }.prefix(4).map { $0 }) }
            .filter { !$0.meanings.isEmpty }.prefix(3).map { $0 }
        card.forms = forms.map { Form(label: clean($0.label), value: clean($0.value)) }
            .filter { !$0.value.isEmpty }.prefix(4).map { $0 }
        card.examples = examples.map { Example(source: clean($0.source), target: clean($0.target)) }
            .filter { !$0.source.isEmpty }.prefix(2).map { $0 }
        card.synonyms = synonyms.map(clean).filter { !$0.isEmpty }.prefix(5).map { $0 }
        return card
    }
}

/// What the AI made of a lookup.
enum AskWordLookup: Equatable, Sendable {
    case card(AskWordCard)
    /// The text was not a word after all; this is its translation.
    case translation(String)
    /// The reply could not be read as a card; shown as it came.
    case unreadable(String)
}

extension AskWordCard {
    /// Longer input is a sentence, whatever it looks like.
    static let maximumLength = 64

    /// Whether `text` gets a word card rather than a translation: one word, or
    /// up to four without sentence punctuation; in Chinese or Japanese, up to six
    /// characters with no punctuation or spaces.
    static func isLookup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, !trimmed.contains(where: \.isNewline) else { return false }
        if containsCJK(trimmed) {
            return trimmed.count <= 6 && !trimmed.unicodeScalars.contains {
                CharacterSet.whitespaces.contains($0) || CharacterSet.punctuationCharacters.contains($0)
            }
        }
        if trimmed.unicodeScalars.contains(where: { ".!?;,:。！？；，：".unicodeScalars.contains($0) }) { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return words.count <= 4 && words.contains { $0.contains(where: \.isLetter) }
    }

    /// Chinese, Japanese or Korean script anywhere in `text`.
    static func containsCJK(_ text: String) -> Bool { text.unicodeScalars.contains(where: isCJK) }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF: true
        default: false
        }
    }

    /// Reads the model's reply: the schema's JSON, possibly inside a code block or prose.
    /// Many providers do not enforce the schema, so the usual alternative names
    /// (`word`, `value`, `parts_of_speech`, `definitions`, …) are read too.
    /// `word` stands in for a missing headword.
    static func parse(_ reply: String, word: String = "") -> AskWordLookup {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = jsonObject(in: trimmed) else { return .unreadable(trimmed) }
        let translation = text(object, "translation", "translated", "result")
        if text(object, "kind", "type")?.lowercased() == "text" {
            return translation.map(AskWordLookup.translation) ?? .unreadable(trimmed)
        }
        let card = AskWordCard(
            headword: text(object, "headword", "word", "term", "entry") ?? word,
            phonetics: phonetics(object), senses: senses(object), forms: forms(object),
            examples: list(object, "examples", "example_sentences", "sentences").compactMap(example),
            synonyms: texts(object, "synonyms", "similar_words", "related")
        ).tidied()
        if !card.headword.isEmpty, !card.senses.isEmpty { return .card(card) }
        return translation.map(AskWordLookup.translation) ?? .unreadable(trimmed)
    }

    /// Whether a reply that could not be read was meant to be structured, so it
    /// must not be shown as it came.
    static func looksStructured(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("```")
            || (trimmed.contains("{") && trimmed.contains("\":"))
    }

    private typealias Object = [String: Any]

    private static func jsonObject(in reply: String) -> Object? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let value = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) else { return nil }
        return value as? Object
    }

    /// The first of `keys` holding text; a list of texts is joined.
    private static func text(_ object: Object, _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let values = object[key] as? [String], !values.isEmpty { return values.joined(separator: meaningSeparator) }
        }
        return nil
    }

    /// The first of `keys` holding one text or several; objects give their text-like field.
    private static func texts(_ object: Object, _ keys: String...) -> [String] {
        for key in keys {
            if let value = object[key] as? String { return value.isEmpty ? [] : [value] }
            if let values = object[key] as? [Any] {
                let found = values.compactMap { item -> String? in
                    if let value = item as? String { return value }
                    guard let item = item as? Object else { return nil }
                    return text(item, "meaning", "definition", "text", "translation", "value", "word")
                }
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    private static func list(_ object: Object, _ keys: String...) -> [Any] {
        for key in keys { if let values = object[key] as? [Any] { return values } }
        return []
    }

    private static func phonetics(_ object: Object) -> [Phonetic] {
        for key in ["phonetics", "pronunciations", "pronunciation", "phonetic", "ipa", "pinyin"] {
            switch object[key] {
            case let value as String: return [Phonetic(label: key == "pinyin" ? "pinyin" : "", text: value)]
            case let byLabel as [String: String]:
                return byLabel.sorted { $0.key < $1.key }.map { Phonetic(label: $0.key, text: $0.value) }
            case let values as [Any]:
                return values.compactMap { item in
                    if let value = item as? String { return Phonetic(label: "", text: value) }
                    guard let item = item as? Object,
                          let value = text(item, "text", "value", "ipa", "phonetic", "pronunciation", "pinyin") else { return nil }
                    return Phonetic(label: text(item, "label", "accent", "region", "dialect", "type") ?? "", text: value)
                }
            default: continue
            }
        }
        return []
    }

    private static func senses(_ object: Object) -> [Sense] {
        list(object, "senses", "parts_of_speech", "partsOfSpeech", "definitions", "meanings", "entries").compactMap { item in
            if let meaning = item as? String { return Sense(pos: "", meanings: [meaning]) }
            guard let item = item as? Object else { return nil }
            return Sense(pos: text(item, "pos", "part_of_speech", "partOfSpeech", "type", "label") ?? "",
                         meanings: texts(item, "meanings", "definitions", "meaning", "definition", "translations",
                                         "translation", "senses"))
        }
    }

    private static func forms(_ object: Object) -> [Form] {
        for key in ["forms", "inflections", "word_forms"] {
            if let byLabel = object[key] as? [String: String] {
                return byLabel.sorted { $0.key < $1.key }.map { Form(label: $0.key, value: $0.value) }
            }
            if let values = object[key] as? [Any] {
                return values.compactMap { item in
                    guard let item = item as? Object, let value = text(item, "value", "form", "word", "text") else { return nil }
                    return Form(label: text(item, "label", "type", "name") ?? "", value: value)
                }
            }
        }
        return []
    }

    private static func example(_ item: Any) -> Example? {
        if let sentence = item as? String { return Example(source: sentence, target: "") }
        guard let item = item as? Object,
              let source = text(item, "source", "sentence", "example", "original", "text") else { return nil }
        return Example(source: source, target: text(item, "target", "translation", "meaning") ?? "")
    }

    /// The structured output the AI is asked for.
    static let schema: LLMJSONSchema = {
        func object(_ properties: [String: AnySendable]) -> AnySendable {
            .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array(properties.keys.sorted().map { .string($0) }),
                "properties": .object(properties)
            ])
        }
        func array(_ items: AnySendable) -> AnySendable { .object(["type": .string("array"), "items": items]) }
        let string = AnySendable.object(["type": .string("string")])
        guard case let .object(root) = object([
            "kind": .object(["type": .string("string"), "enum": .array([.string("word"), .string("text")])]),
            "headword": string,
            "phonetics": array(object(["label": string, "text": string])),
            "senses": array(object(["pos": string, "meanings": array(string)])),
            "forms": array(object(["label": string, "value": string])),
            "examples": array(object(["source": string, "target": string])),
            "synonyms": array(string),
            "translation": string
        ]) else { return LLMJSONSchema(name: "word_card", schema: [:]) }
        return LLMJSONSchema(name: "word_card", schema: root)
    }()
}
