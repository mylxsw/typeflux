import Foundation
import Testing
@testable import Typeflux

struct EmojiSearchTests {
    static func entry(_ emoji: String, _ name: String, _ tags: [String], variants: [EmojiVariant] = []) -> EmojiEntry {
        EmojiEntry(id: emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-"), sequence: emoji,
                   names: ["en": name, "zh": tags.first ?? name], keywords: tags + [name], group: "test",
                   version: "1.0",
                   variants: variants)
    }

    static let catalog = EmojiCatalog(schema: 1, entries: [
        entry("😊", "smile", ["开心", "微笑", "happy", "smile"]),
        entry(
            "🙏",
            "folded hands",
            ["感谢", "感謝", "thanks"],
            variants: [.init(sequence: "🙏🏽", names: ["en": "medium skin tone"])]
        ),
        entry("❤️", "red heart", ["红心", "red", "heart", "love"]),
        entry("😭", "cry", ["伤心", "sad"]),
        entry("🎂", "birthday cake", ["生日", "蛋糕", "birthday", "cake"]),
        entry("🎉", "party popper", ["庆祝", "party", "birthday"])
    ])
    static func service() -> EmojiSearchService {
        EmojiSearchService(load: { catalog }, supported: { _ in true })
    }

    @Test func `names and variants`() {
        let entry = Self.catalog.entries[1]
        #expect(entry.name(.simplifiedChinese) == "感谢")
        #expect(entry.name(.english) == "folded hands")
        #expect(entry.name(.traditionalChinese) == "folded hands")
        #expect(entry.name(.english, sequence: "🙏🏽") == "medium skin tone")
        #expect(entry.sequence(preferred: "invalid") == "🙏")
        #expect(entry.sequence(preferred: "🙏🏽") == "🙏🏽")
        #expect(entry.sequence(preferred: nil) == "🙏")
    }

    @Test func `multilingual and typo queries`() async throws {
        let service = Self.service()
        for (query, emoji) in [("开心", "😊"), ("感謝", "🙏"), ("kaixin", "😊"), ("kx", "😊"), ("SMILE", "😊"),
                               (":smile:", "😊"), ("ＳＭＩＬＥ", "😊"), ("smiel", "😊"), ("smle", "😊"), ("smil", "😊"),
                               ("red_heart", "❤️"), ("red heart", "❤️"), ("❤️", "❤️"), ("❤", "❤️"), ("🙏🏽", "🙏"),
                               ("irth", "🎂")] {
            let result = try await service.search(query)
            #expect(result.first?.entry.sequence == emoji, "Query: \(query)")
        }
        #expect(try await service.search("red birthday").isEmpty)
        #expect(try await service.search("not happy").first?.entry.sequence == "😭")
        #expect(try await service.search("not smile").isEmpty)
        #expect(try await service.search("不想庆祝").isEmpty)
        #expect(try await service.search("星际传送门").isEmpty)
        #expect(try await service.search(String(repeating: "a", count: 161)).isEmpty)
        #expect(try await service.search("", limit: 0).isEmpty)
        #expect(try await service.search("生日快乐").map(\.entry.sequence) == ["🎂", "🎉"])
    }

    @Test func `scopes and stable ranking`() async throws {
        let service = Self.service()
        let entries = Self.catalog.entries
        let usage = EmojiUsage(
            recent: [.init(id: entries[2].id, sequence: "❤️", count: 5, date: Date())],
            favorites: [entries[1].id]
        )
        #expect(try await service.search("", usage: usage).first?.entry.sequence == "❤️")
        #expect(try await service.search("", scope: .recent, usage: usage).map(\.entry.sequence) == ["❤️"])
        #expect(try await service.search("", scope: .favorites, usage: usage).map(\.entry.sequence) == ["🙏"])
        #expect(try await service.search("red", scope: .favorites, usage: usage).isEmpty)
        #expect(try await service.search("", limit: 2).count == 2)
        #expect(try await service.search("smile", usage: usage).first?.entry.sequence == "😊")
    }

    @Test func `browsing returns the complete supported catalog beyond legacy limits`() async throws {
        let catalog = try EmojiCatalog.load()
        #expect(catalog.entries.count > 200)
        let excluded = catalog.entries[0].sequence
        let service = EmojiSearchService(load: { catalog }, supported: { $0 != excluded })
        let results = try await service.search("  ")
        #expect(results.map(\.entry.id) == catalog.entries.dropFirst().map(\.id))
        #expect(try await service.search("", limit: 250).count == 250)
        let usage = EmojiUsage(favorites: Set(catalog.entries.map(\.id)))
        #expect(try await service.search("", scope: .favorites, usage: usage).count == results.count)
    }

    @Test func `edit distance boundaries`() {
        for (left, right, expected) in [
            ("smile", "smiel", 1),
            ("cat", "cat", 0),
            ("", "a", 1),
            ("a", "", 1),
            ("dog", "cat", 3),
            ("cake", "cage", 1)
        ] {
            #expect(EmojiSearchService.distance(left, right, limit: 3) == expected)
        }
        #expect(EmojiSearchService.distance("abcdefgh", "x", limit: 1) > 1)
        #expect(EmojiSearchService.distance("abcd", "zzzz", limit: 1) > 1)
        #expect(EmojiSearchService.normalize("  :RED_HEART:  ") == "red heart")
    }

    @Test func `loading validation and cancellation`() async throws {
        let encoded = try JSONEncoder().encode(Self.catalog)
        #expect(try EmojiCatalog.decode(encoded).entries.count == 6)
        #expect(throws: (any Error).self) { try EmojiCatalog.decode(Data()) }
        #expect(throws: (any Error).self) { try EmojiCatalog.decode(JSONEncoder().encode(EmojiCatalog(
            schema: 9,
            entries: Self.catalog.entries
        ))) }
        #expect(throws: (any Error).self) { try EmojiCatalog.decode(JSONEncoder().encode(EmojiCatalog(
            schema: 1,
            entries: []
        ))) }
        let failed = EmojiSearchService(load: { throw CocoaError(.fileReadCorruptFile) })
        await #expect(throws: (any Error).self) { try await failed.search("x") }
        let empty = EmojiSearchService(load: { Self.catalog }, supported: { _ in false })
        #expect(try await empty.search("").isEmpty)
        let task = Task { try await Self.service().search("smile") }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch {
            Issue.record(error)
        }
    }

    @Test func `curated query quality`() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let cases = try JSONDecoder().decode(
            [[String]].self,
            from: Data(contentsOf: root.appendingPathComponent("scripts/emoji/search-cases.json"))
        )
        #expect(cases.count >= 200)
        let service = EmojiSearchService(load: { try EmojiCatalog.load() }, supported: { _ in true })
        var missed: [String] = []
        for pair in cases {
            let matches = try await service.search(pair[0])
            if !matches.prefix(5).contains(where: { pair.dropFirst().contains($0.entry.sequence) }) {
                missed.append(pair[0])
            }
        }
        print("Emoji curated Top-5: \(cases.count - missed.count)/\(cases.count); misses: \(missed)")
        #expect(Double(cases.count - missed.count) / Double(cases.count) >= 0.9)
    }

    @Test func `bundled catalog and query benchmark`() async throws {
        let catalog = try EmojiCatalog.load()
        #expect(catalog.entries.count > 1900)
        #expect(catalog.entries.contains { $0.sequence == "👩‍💻" })
        #expect(catalog.entries.contains { $0.sequence == "🇨🇳" })
        #expect(catalog.entries.first { $0.sequence == "🙏" }?.variants.contains { $0.sequence == "🙏🏽" } == true)
        let service = EmojiSearchService()
        let start = Date()
        _ = try await service.search("")
        print("Emoji cold catalog: \(Date().timeIntervalSince(start) * 1000) ms")
        let cases: [(String, String)] = [("想表达感谢", "🙏"), ("不想上班", "😮‍💨"), ("生日快乐", "🎂"), ("smiel", "😀"),
                                         ("red heart", "❤️"), ("👩‍💻", "👩‍💻"), ("🇨🇳", "🇨🇳"), ("不开心", "😢")]
        var timings: [Double] = []
        for _ in 0 ..< 3 {
            for (query, expected) in cases {
                let start = Date()
                let results = try await service.search(query)
                timings.append(Date().timeIntervalSince(start) * 1000)
                #expect(results.prefix(5).contains { $0.entry.sequence == expected }, "Query: \(query)")
            }
        }
        print("Emoji warm P95: \(timings.sorted()[Int(Double(timings.count - 1) * 0.95)]) ms")
        #expect(EmojiCatalog.supports("😊"))
        #expect(!EmojiCatalog.supports("ab"))
    }
}
