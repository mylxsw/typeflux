import Foundation
import Testing
@testable import Typeflux

@Suite("Ask fuzzy matcher")
struct AskFuzzyMatcherTests {
    private func score(_ query: String, _ name: String, file: Bool = false, fuzzy: Bool = true) -> Double? {
        AskFuzzyMatcher.match(AskSearchQuery(query).compact, AskSearchKey(name, hasExtension: file), fuzzy: fuzzy)?.score
    }

    /// The characters of `name` that matched, as text.
    private func marked(_ query: String, _ name: String, file: Bool = false) -> [String] {
        let found = AskFuzzyMatcher.match(AskSearchQuery(query).compact, AskSearchKey(name, hasExtension: file), ranges: true)
        let characters = Array(name)
        return AskSearchText.characterRanges(found?.ranges ?? [], in: name).map { String(characters[$0]) }
    }

    @Test(arguments: [
        ("wechat", "WeChat", AskFuzzyMatcher.exact),
        ("weixin", "微信", AskFuzzyMatcher.pinyinExact),
        ("wech", "WeChat", AskFuzzyMatcher.prefix),
        ("vsc", "Visual Studio Code", AskFuzzyMatcher.initials),
        ("wx", "微信", AskFuzzyMatcher.initials),
        ("weix", "微信", AskFuzzyMatcher.pinyinPrefix),
        ("studio", "Visual Studio Code", AskFuzzyMatcher.wordPrefix),
        ("plus", "TablePlus", AskFuzzyMatcher.wordPrefix),
        ("vs", "Visual Studio Code", AskFuzzyMatcher.initialsPrefix),
        ("hetong", "2026 年度采购合同", AskFuzzyMatcher.pinyinLater),
        ("ht", "2026 年度采购合同", AskFuzzyMatcher.pinyinInitialsLater),
        ("hat", "WeChat", AskFuzzyMatcher.contains),
        ("visualstudio", "Visual Studio Code", AskFuzzyMatcher.prefix)
    ])
    func scoresByTier(query: String, name: String, expected: Double) {
        #expect(score(query, name) == expected, "\(query) → \(name)")
    }

    @Test func aFileMatchesExactlyWithoutItsExtension() {
        #expect(score("readme", "README.md", file: true) == AskFuzzyMatcher.exact)
        #expect(score("readme", "README.md") == AskFuzzyMatcher.prefix, "only files drop the extension")
        #expect(score("readme.md", "README.md", file: true) == AskFuzzyMatcher.exact)
        #expect(AskSearchKey(".env", hasExtension: true).extensionStart == nil, "a dot file has no extension")
        #expect(AskSearchKey("archive.", hasExtension: true).extensionStart == nil)
    }

    @Test func lettersInOrderScoreByHowCloseTheyAre() throws {
        let close = try #require(score("tbpls", "TablePlus"))
        let far = try #require(score("tlu", "TablePlus"))
        #expect(close > AskFuzzyMatcher.inOrder && close <= AskFuzzyMatcher.inOrder + 0.1)
        #expect(far >= AskFuzzyMatcher.inOrder && far < close)
        #expect(score("tbpls", "TablePlus", fuzzy: false) == nil, "the setting turns it off")
        #expect(score("tb", "TablePlus") == nil, "two letters are too few to guess from")
        #expect(score("中文字", "中 x 文 y 字") == nil, "only Latin letters are matched in order")
    }

    @Test func foldsCaseAccentsAndWidth() {
        #expect(score("cafe", "Café") == AskFuzzyMatcher.exact)
        #expect(score("ＷＥＣＨＡＴ", "WeChat") == AskFuzzyMatcher.exact)
        #expect(score("CAFÉ", "cafe") == AskFuzzyMatcher.exact)
        #expect(score("über", "Übersicht") == AskFuzzyMatcher.prefix)
    }

    @Test func nothingMatchesNothing() {
        #expect(score("", "WeChat") == nil)
        #expect(score("zzz", "WeChat") == nil)
        #expect(score("h", "WeChat") == nil, "one letter does not match inside a word")
        #expect(score("x", "") == nil)
    }

    @Test func highlightsWhatMatched() {
        #expect(marked("wech", "WeChat") == ["WeCh"])
        #expect(marked("hat", "WeChat") == ["hat"])
        #expect(marked("vsc", "Visual Studio Code") == ["V", "S", "C"])
        #expect(marked("ht", "2026 年度采购合同.pdf", file: true) == ["合同"])
        #expect(marked("hetong", "2026 年度采购合同.pdf", file: true) == ["合同"])
        #expect(marked("weixin", "微信") == ["微信"])
        #expect(marked("weix", "微信") == ["微信"], "a syllable begun counts as matched")
        #expect(marked("cafe", "Café") == ["Café"])
        #expect(marked("tbpls", "TablePlus") == ["T", "b", "Pl", "s"], "letters side by side read as one run")
        #expect(marked("readme", "README.md", file: true) == ["README"])
    }

    @Test func pinyinReadsWordsAndLatinRuns() throws {
        let music = AskPinyinKey("QQ音乐")
        #expect(String(decoding: music.spelling, as: UTF8.self) == "qqyinyue")
        #expect(music.syllables.map(\.han) == [false, true, true])
        #expect(String(decoding: music.initials, as: UTF8.self) == "qyy")
        let bank = AskPinyinKey("招商银行")
        #expect(String(decoding: bank.spelling, as: UTF8.self) == "zhaoshangyinhang", "known words read correctly")
        #expect(score("qyy", "QQ音乐") == AskFuzzyMatcher.initials)
        #expect(score("qqyin", "QQ音乐") == AskFuzzyMatcher.pinyinPrefix)
        #expect(score("yinyue", "QQ音乐") == AskFuzzyMatcher.pinyinLater)
        #expect(score("h", "2026 年度采购合同") == nil, "a single letter never reads as a later character")
        #expect(AskPinyinKey("").syllables.isEmpty)
    }

    @Test func wordsStartAfterSeparatorsAndCaseChanges() {
        #expect(AskSearchText.wordStarts("Visual Studio Code") == [0, 7, 14])
        #expect(AskSearchText.wordStarts("TablePlus") == [0, 5])
        #expect(AskSearchText.wordStarts("final_cut-pro") == [0, 6, 10])
        #expect(AskSearchText.wordStarts("  lead") == [2])
        #expect(AskSearchText.wordStarts("") == [])
    }

    @Test func masksCoverTheirCharacters() {
        let name = AskSearchKey("WeChat 微信")
        #expect(name.mask & AskSearchQuery("wct").mask == AskSearchQuery("wct").mask)
        #expect(name.mask & AskSearchQuery("weixin").mask == AskSearchQuery("weixin").mask, "pinyin letters count")
        #expect(name.mask & AskSearchQuery("zq").mask != AskSearchQuery("zq").mask)
        #expect(AskSearchText.mask([UInt8(ascii: " ")]) == 0)
    }

    @Test func characterRangesMapFoldedBytesBack() {
        #expect(AskSearchText.characterRanges([0 ..< 3], in: "微信") == [0 ..< 1], "a Chinese character is three bytes")
        #expect(AskSearchText.characterRanges([0 ..< 1, 1 ..< 2], in: "ab") == [0 ..< 2], "touching ranges merge")
        #expect(AskSearchText.characterRanges([5 ..< 9], in: "ab") == [], "out of range is dropped")
        #expect(AskSearchText.normalize("ÄB") == Array("ab".utf8))
    }
}

@Suite("Ask search query")
struct AskSearchQueryTests {
    @Test func splitsWordsAndFilters() {
        let query = AskSearchQuery("Typeflux .MD in:Design")
        #expect(query.words == [Array("typeflux".utf8)])
        #expect(query.fileExtension == "md")
        #expect(query.folder == Array("design".utf8))
        #expect(query.hasFilters)
        #expect(!query.isEmpty)
        let ext = AskSearchQuery("report ext:.pdf")
        #expect(ext.fileExtension == "pdf")
        #expect(ext.compact == Array("report".utf8))
    }

    @Test func dropsPunctuationButKeepsNameMarks() {
        #expect(AskSearchQuery("wechat?").compact == Array("wechat".utf8))
        #expect(AskSearchQuery("v1.2-final_cut").compact == Array("v1.2-final_cut".utf8))
        #expect(AskSearchQuery("？？").isEmpty)
    }

    @Test func onlyShortOneLineTextIsSearchable() {
        #expect(AskSearchQuery("wx").isSearchable)
        #expect(!AskSearchQuery("a\nb").isSearchable)
        #expect(!AskSearchQuery(String(repeating: "a", count: 41)).isSearchable)
        #expect(!AskSearchQuery("   ").isSearchable)
        #expect(!AskSearchQuery(".pdf").isSearchable, "a filter alone names nothing")
        #expect(AskSearchQuery("ext:").words == [Array("ext".utf8)], "an empty filter is just a word")
    }
}

@Suite("Ask launcher search settings")
struct AskLauncherSearchSettingsTests {
    @Test func defaultsAndOldSavesLoad() throws {
        let defaults = AskLauncherSearchSettings()
        #expect(defaults.mode == .mixed && defaults.fuzzy && defaults.limit == 30)
        #expect(defaults.fileRoots == ["~"])
        #expect(defaults.excludedFolderNames.contains("node_modules"))
        let old = try JSONDecoder().decode(AskLauncherSearchSettings.self, from: Data(#"{"mode":"filesFirst","limit":7}"#.utf8))
        #expect(old.mode == .mixed)
        #expect(old.limit == 30, "a limit not offered falls back")
        #expect(old.appRoots == AskLauncherSearchSettings.defaultAppRoots)
        let round = try JSONDecoder().decode(AskLauncherSearchSettings.self, from: JSONEncoder().encode(old))
        #expect(round == old)
    }

    @Test func legacySearchModesUseMixedWithoutResettingOtherPreferences() throws {
        let suite = "ask-search-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        for mode in ["mixed", "appsFirst", "filesFirst", "obsolete"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "mode": mode, "fuzzy": false, "limit": 50, "fileIcons": "icons",
                "appRoots": ["~/Apps"], "fileRoots": ["~/Work"], "includeHidden": true
            ])
            defaults.set(data, forKey: "ask.search.settings")
            let settings = store.askLauncherSearchSettings
            #expect(settings.mode == .mixed)
            #expect(!settings.fuzzy && settings.limit == 50 && settings.fileIcons == .icons)
            #expect(settings.appRoots == ["~/Apps"] && settings.fileRoots == ["~/Work"] && settings.includeHidden)
            store.askLauncherSearchSettings = settings
            #expect(SettingsStore(defaults: defaults).askLauncherSearchSettings == settings)
        }
        var changed = store.askLauncherSearchSettings
        changed.mode = .filesFirst
        store.askLauncherSearchSettings = changed
        let saved = try #require(defaults.data(forKey: "ask.search.settings"))
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["mode"] as? String == "mixed")
    }

    @Test func pathsExpandAndAbbreviate() {
        #expect(AskLauncherSearchSettings.expand("~", home: "/Users/a") == "/Users/a")
        #expect(AskLauncherSearchSettings.expand("~/Docs/", home: "/Users/a") == "/Users/a/Docs")
        #expect(AskLauncherSearchSettings.expand(" /Volumes/W ", home: "/Users/a") == "/Volumes/W")
        #expect(AskLauncherSearchSettings.expand("/", home: "/Users/a") == "/")
        #expect(AskLauncherSearchSettings.abbreviate("/Users/a/Docs", home: "/Users/a") == "~/Docs")
        #expect(AskLauncherSearchSettings.abbreviate("/Users/a", home: "/Users/a") == "~")
        #expect(AskLauncherSearchSettings.abbreviate("/Users/ab", home: "/Users/a") == "/Users/ab")
    }

    @Test func cleansWhatTheUserTypes() {
        #expect(AskLauncherSearchSettings.cleanExtension(" .LOG ") == "log")
        #expect(AskLauncherSearchSettings.cleanExtension("*.tmp") == "tmp")
        #expect(AskLauncherSearchSettings.cleanExtension(".") == nil)
        #expect(AskLauncherSearchSettings.cleanExtension("a/b") == nil)
        #expect(AskLauncherSearchSettings.cleanFolderName(" node_modules ") == "node_modules")
        #expect(AskLauncherSearchSettings.cleanFolderName("a/b") == nil)
        #expect(AskLauncherSearchSettings.cleanFolderName("  ") == nil)
    }

    @Test func theFingerprintFollowsWhatTheIndexDependsOn() {
        var settings = AskLauncherSearchSettings()
        let base = settings.fileIndexFingerprint
        settings.mode = .appsFirst
        settings.fuzzy = false
        #expect(settings.fileIndexFingerprint == base, "ranking options do not rebuild the index")
        settings.includeHidden = true
        #expect(settings.fileIndexFingerprint != base)
    }

    @Test func theStoreSavesAndAnnounces() throws {
        let suite = "ask-search-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.askLauncherSearchSettings == AskLauncherSearchSettings())
        #expect(store.askQuickFileSearchEnabled)
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: .askLauncherSearchSettingsDidChange, object: store,
                                                              queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var changed = AskLauncherSearchSettings()
        changed.fileRoots = ["~/Work"]
        store.askLauncherSearchSettings = changed
        #expect(store.askLauncherSearchSettings.fileRoots == ["~/Work"])
        #expect(posted == 1)
        store.askQuickFileSearchEnabled = false
        #expect(!store.askQuickFileSearchEnabled)
        defaults.set(Data("not json".utf8), forKey: "ask.search.settings")
        #expect(store.askLauncherSearchSettings == AskLauncherSearchSettings(), "damaged settings read as defaults")
    }
}
