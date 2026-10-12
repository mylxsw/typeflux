import CoreText
import Foundation

struct EmojiVariant: Codable, Equatable, Sendable {
    var sequence: String
    var names: [String: String]
}

struct EmojiEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sequence: String
    var names: [String: String]
    var keywords: [String]
    var group: String
    var version: String
    var variants: [EmojiVariant]
    var pinyin: [String]?

    func name(_ language: AppLanguage, sequence: String? = nil) -> String {
        let names = variants.first { $0.sequence == sequence }?.names ?? self.names
        let locale = language == .simplifiedChinese ? "zh" : language.rawValue
        return names[locale] ?? names["en"] ?? self.sequence
    }

    func sequence(preferred: String?) -> String {
        guard let preferred, variants.contains(where: { $0.sequence == preferred }) else { return sequence }
        return preferred
    }
}

struct EmojiCatalog: Codable, Sendable {
    var schema: Int
    var entries: [EmojiEntry]

    static func load() throws -> Self {
        guard let url = Bundle.appResources.url(forResource: "emoji-catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schema == 1, !catalog.entries.isEmpty,
              Set(catalog.entries.map(\.id)).count == catalog.entries.count,
              catalog.entries.allSatisfy({ !$0.id.isEmpty && !$0.sequence.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return catalog
    }

    /// A supported emoji shapes as one non-missing glyph, including ZWJ/flag sequences.
    static func supports(_ sequence: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let text = NSAttributedString(
            string: sequence,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(text)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        guard runs.reduce(0, { $0 + CTRunGetGlyphCount($1) }) == 1 else { return false }
        return runs.allSatisfy { run in
            var glyph = CGGlyph()
            CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
            return glyph != 0
        }
    }
}

enum EmojiScope: String, Codable, CaseIterable, Sendable {
    case all, recent, favorites
    var title: String {
        L("emoji.scope." + rawValue)
    }
}

struct EmojiUsage: Codable, Equatable, Sendable {
    struct Recent: Codable, Equatable, Sendable {
        var id: String
        var sequence: String
        var count: Int
        var date: Date
    }

    var recent: [Recent] = []
    var favorites: Set<String> = []
    var variants: [String: String] = [:]
}

@MainActor
final class EmojiUsageStore {
    static let key = "launcher.emoji.usage.v1"
    private let defaults: UserDefaults
    private(set) var value: EmojiUsage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        value = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(EmojiUsage.self, from: $0) } ?? EmojiUsage()
        value.recent = Array(value.recent.prefix(50))
    }

    func record(id: String, sequence: String, at date: Date = Date()) {
        let count = value.recent.first { $0.id == id }?.count ?? 0
        value.recent.removeAll { $0.id == id }
        value.recent.insert(.init(id: id, sequence: sequence, count: min(count, 9999) + 1, date: date), at: 0)
        value.recent = Array(value.recent.prefix(50))
        save()
    }

    func toggleFavorite(_ id: String) {
        if !value.favorites.insert(id).inserted {
            value.favorites.remove(id)
        }
        save()
    }

    func setVariant(_ sequence: String, for id: String) {
        value.variants[id] = sequence
        save()
    }

    func clearRecent() {
        value.recent = []; save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
