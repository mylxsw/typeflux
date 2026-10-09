import AppKit
import Foundation
import Testing
@testable import Typeflux

/// A fixed application list for launcher tests.
final class AskTestAppIndex: AskAppSearching, @unchecked Sendable {
    var entries: [AskAppEntry]
    private(set) var refreshes = 0
    private(set) var launched: [String] = []

    init(_ entries: [AskAppEntry]) { self.entries = entries }

    func search(_ query: String, limit: Int) -> [AskAppMatch] {
        AskAppMatcher.search(query, in: entries, limit: limit)
    }

    func refreshIfStale() { refreshes += 1 }
    func recordLaunch(_ entry: AskAppEntry) { launched.append(entry.id) }

    static func app(_ name: String, _ names: [String] = [], id: String? = nil) -> AskAppEntry {
        AskAppEntry(name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                    bundleID: id ?? "test." + name.lowercased().filter(\.isLetter), names: names)
    }

    static let sample = AskTestAppIndex([
        app("微信", ["WeChat"], id: "com.tencent.xinWeChat"),
        app("Visual Studio Code", ["Code"], id: "com.microsoft.VSCode"),
        app("TablePlus"),
        app("计算器", ["Calculator"], id: "com.apple.calculator"),
        app("Notes", ["备忘录"], id: "com.apple.Notes"),
        app("QQ音乐", ["QQMusic"], id: "com.tencent.QQMusicMac")
    ])
}

@Suite("Ask app entry")
struct AskAppEntryTests {
    @Test func namesAreLoweredAndDeduplicated() {
        let entry = AskAppEntry(name: "WeChat", url: URL(fileURLWithPath: "/Applications/WeChat.app"),
                                bundleID: "com.tencent.xinWeChat", names: ["WeChat", " 微信 ", "", "wechat"])
        #expect(entry.names == ["wechat", "微信"])
        #expect(entry.pinyin == ["weixin"])
        #expect(entry.pinyinInitials == ["wx"])
        #expect(entry.id == "com.tencent.xinWeChat")
        let unnamed = AskAppEntry(name: "Tool", url: URL(fileURLWithPath: "/Applications/Tool.app"), bundleID: nil, names: [])
        #expect(unnamed.id == "/Applications/Tool.app")
    }

    @Test func initialsSplitWordsAndCamelCase() {
        #expect(AskAppEntry.initials(of: "Visual Studio Code") == "vsc")
        #expect(AskAppEntry.initials(of: "TablePlus") == "tp")
        #expect(AskAppEntry.initials(of: "Final_Cut-Pro") == "fcp")
        #expect(AskAppEntry.initials(of: "Safari") == nil)
        #expect(AskAppEntry.initials(of: "QQ音乐") == nil)
    }

    @Test func pinyinKeepsLatinRuns() {
        #expect(AskAppEntry.pinyinSyllables("微信") == ["wei", "xin"])
        #expect(AskAppEntry.pinyinSyllables("QQ音乐") == ["qq", "yin", "yue"])
        #expect(AskAppEntry.pinyinSyllables("招商银行") == ["zhao", "shang", "yin", "hang"], "known words read correctly")
        #expect(AskAppEntry.pinyinSyllables("网易云音乐") == ["wang", "yi", "yun", "yin", "yue"])
        #expect(AskAppEntry.containsHan("QQ音乐"))
        #expect(!AskAppEntry.containsHan("Safari"))
    }
}

@Suite("Ask app matcher")
struct AskAppMatcherTests {
    private let index = AskTestAppIndex.sample

    private func top(_ query: String) -> String? { index.search(query, limit: 5).first?.entry.name }

    @Test(arguments: [
        ("微信", "微信"), ("wechat", "微信"), ("wx", "微信"), ("weixin", "微信"), ("weix", "微信"),
        ("vsc", "Visual Studio Code"), ("code", "Visual Studio Code"), ("studio", "Visual Studio Code"),
        ("tp", "TablePlus"), ("table", "TablePlus"), ("jsq", "计算器"), ("calc", "计算器"), ("计算", "计算器"),
        ("备忘", "Notes"), ("qyy", "QQ音乐"), ("qqyin", "QQ音乐"), ("qqmusic", "QQ音乐"), ("tbpls", "TablePlus")
    ])
    func findsApplications(query: String, expected: String) {
        #expect(top(query) == expected, "\(query)")
    }

    @Test(arguments: ["", "  ", "x", "zzz", "how to cook rice", String(repeating: "a", count: 41), "wx\nwx"])
    func ignoresTextThatNamesNothing(query: String) {
        #expect(index.search(query, limit: 5).isEmpty, "\(query)")
    }

    @Test func scoresByStrength() throws {
        let wechat = AskTestAppIndex.sample.entries[0]
        #expect(AskAppMatcher.score("wechat", wechat) == 1)
        #expect(AskAppMatcher.score("wech", wechat) == 0.9)
        #expect(AskAppMatcher.score("weixin", wechat) == 0.95)
        #expect(AskAppMatcher.score("wx", wechat) == 0.88)
        #expect(AskAppMatcher.score("hat", wechat) == 0.6)
        #expect(AskAppMatcher.score("wct", wechat) == 0.5, "letters in order: 0.45, plus up to 0.1 the closer they are")
        #expect(AskAppMatcher.score("w", wechat) == 0.9, "one letter still finds a name it starts")
        #expect(AskAppMatcher.score("h", wechat) == nil, "but not one it merely contains")
        let code = AskTestAppIndex.sample.entries[1]
        #expect(AskAppMatcher.score("vs", code) == 0.8)
        #expect(AskAppMatcher.score("visual studio", code) == 0.9)
    }

    @Test func launchesAndShorterNamesBreakTies() {
        let notes = AskTestAppIndex.app("Notes", id: "a")
        let notebook = AskTestAppIndex.app("Notebook", id: "b")
        #expect(AskAppMatcher.search("note", in: [notebook, notes]).map(\.entry.id) == ["a", "b"])
        #expect(AskAppMatcher.search("note", in: [notes, notebook], launches: ["b": 5]).map(\.entry.id) == ["b", "a"])
        let alpha = AskTestAppIndex.app("Beta", id: "beta"), beta = AskTestAppIndex.app("Bear", id: "bear")
        #expect(AskAppMatcher.search("be", in: [alpha, beta]).map(\.entry.id) == ["bear", "beta"])
        #expect(AskAppMatcher.search("be", in: [alpha, beta], limit: 1).count == 1)
    }

    @Test func onlyShortClearQueriesTakeReturn() {
        let strong = AskAppMatch(entry: AskTestAppIndex.sample.entries[0], score: 0.9)
        let weak = AskAppMatch(entry: AskTestAppIndex.sample.entries[0], score: 0.6)
        #expect(AskAppMatcher.isStrong(strong, query: "wx"))
        #expect(AskAppMatcher.isStrong(strong, query: "visual studio code"))
        #expect(!AskAppMatcher.isStrong(weak, query: "wx"))
        #expect(!AskAppMatcher.isStrong(nil, query: "wx"))
        #expect(!AskAppMatcher.isStrong(strong, query: "w"))
        #expect(!AskAppMatcher.isStrong(strong, query: "wechat?"))
        #expect(!AskAppMatcher.isStrong(strong, query: "open wechat on my mac"))
        #expect(!AskAppMatcher.isStrong(strong, query: "微信，"))
    }
}

@Suite("Ask app index", .serialized)
struct AskAppIndexTests {
    /// Builds a folder of minimal application bundles.
    private func makeApps() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-apps-\(UUID().uuidString)")
        func app(_ path: String, id: String, name: String, chinese: String? = nil, background: Bool = false,
                 loctable: Bool = false) throws {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            if background { info["LSBackgroundOnly"] = true }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            guard let chinese else { return }
            if loctable {
                let table = ["zh_CN": ["CFBundleDisplayName": chinese], "en": ["CFBundleDisplayName": name]]
                try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
                    .write(to: resources.appendingPathComponent("InfoPlist.loctable"))
            } else {
                let lproj = resources.appendingPathComponent("zh-Hans.lproj")
                try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                try Data("\"CFBundleDisplayName\" = \"\(chinese)\";\n".utf8)
                    .write(to: lproj.appendingPathComponent("InfoPlist.strings"))
            }
        }
        try app("WeChat.app", id: "com.tencent.xinWeChat", name: "WeChat", chinese: "微信")
        try app("Utilities/Calculator.app", id: "com.apple.calculator", name: "Calculator", chinese: "计算器", loctable: true)
        try app("Helper.app", id: "test.helper", name: "Helper", background: true)
        try app("Later/WeChat.app", id: "com.tencent.xinWeChat", name: "WeChat Copy")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("readme.txt"))
        return root
    }

    @Test func scanReadsNamesInEveryLanguage() throws {
        let root = try makeApps()
        defer { try? FileManager.default.removeItem(at: root) }
        // The copy in Later/ is found again through the second root, after the first.
        let entries = AskAppIndex.scan([root, root.appendingPathComponent("Later"), root.appendingPathComponent("Missing")])
        #expect(Set(entries.map(\.id)) == ["com.tencent.xinWeChat", "com.apple.calculator"], "background-only and duplicates are left out")
        let wechat = try #require(entries.first { $0.id == "com.tencent.xinWeChat" })
        #expect(wechat.names.contains("微信"))
        #expect(wechat.pinyinInitials == ["wx"])
        let calculator = try #require(entries.first { $0.id == "com.apple.calculator" })
        #expect(calculator.names.contains("计算器"), "Apple's apps keep names in InfoPlist.loctable")
        #expect(AskAppIndex.scan([root.appendingPathComponent("WeChat.app")]).count == 1, "a root can be one app")
    }

    @Test func hiddenApplicationLinksAreIndexedAndDeduplicated() throws {
        let root = try makeApps()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("WeChat.app"))
        var hidden = URLResourceValues()
        hidden.isHidden = true
        var hiddenURL = link
        try hiddenURL.setResourceValues(hidden)
        let entries = AskAppIndex.scan([root, link])
        #expect(entries.filter { $0.id == "com.tencent.xinWeChat" }.count == 1)
        #expect(entries.first { $0.id == "com.tencent.xinWeChat" }?.url.path == AskFileScope.canonical(root.path) + "/Safari.app")
        #expect(AskAppIndex.scan([link]).first?.url == link)
        #expect(AskLauncherSearchSettings.defaultAppRoots.contains("/System/Cryptexes/App/System/Applications"))
    }

    @Test func searchesAfterARefreshAndRemembersLaunches() throws {
        let root = try makeApps()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ask-apps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = AskAppIndex(roots: [root], defaults: defaults)
        #expect(index.search("wx", limit: 5).isEmpty, "nothing before the first scan")
        index.refreshNow()
        let match = try #require(index.search("wx", limit: 5).first)
        #expect(match.entry.id == "com.tencent.xinWeChat")
        index.recordLaunch(match.entry)
        #expect((defaults.dictionary(forKey: "ask.quickResults.appLaunches") as? [String: Int])?["com.tencent.xinWeChat"] == 1)
        #expect(try #require(index.search("wx", limit: 5).first).score > match.score)
        let reopened = AskAppIndex(roots: [root], defaults: defaults)
        reopened.refreshNow()
        #expect(try #require(reopened.search("wx", limit: 5).first).score > match.score, "launch counts persist")
    }

    @Test func refreshIfStaleScansInTheBackgroundOnce() async throws {
        let root = try makeApps()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ask-apps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = AskAppIndex(roots: [root], defaults: defaults)
        index.refreshIfStale()
        index.refreshIfStale()
        // The scan runs at utility QoS, which a loaded Mac can delay by seconds; stop as soon as it lands.
        for _ in 0 ..< 2000 where index.search("calc", limit: 5).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(index.search("calc", limit: 5).first?.entry.id == "com.apple.calculator")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Utilities"))
        index.refreshIfStale()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!index.search("calc", limit: 5).isEmpty, "a fresh list is not scanned again")
    }

    @Test func defaultsCoverTheUsualFolders() {
        let paths = AskAppIndex.defaultRoots.map(\.path)
        #expect(paths.contains("/Applications"))
        #expect(paths.contains("/System/Applications"))
        #expect(paths.contains { $0.hasSuffix("/Applications") && $0.hasPrefix(NSHomeDirectory()) })
        #expect(AskAppIndex.shared === AskAppIndex.shared)
    }

    @Test(.exclusiveUIState) @MainActor func iconsAreCached() async throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let key = AskResultImageCache.Key(url: url, thumbnail: false)
        let cache = AskResultImageCache()
        let first = try #require(await cache.image(key))
        #expect(await cache.image(key) === first)
    }
}

@Suite("Ask quick results with apps", .exclusiveUIState)
struct AskQuickResultsAppTests {
    private let apps = AskTestAppIndex(AskTestAppIndex.sample.entries)

    private func resolve(_ text: String, previous: AskQuickResults? = nil, calculator: Bool = true) -> AskQuickResults? {
        AskQuickResults.resolve(text: text, previous: previous, chinese: true, calculator: calculator, apps: apps)
    }

    @Test func aClearNameLeadsAndTakesReturn() throws {
        let results = try #require(resolve("wx"))
        #expect(results.appsLead)
        #expect(results.rows == [.app(0), .askAI])
        #expect(results.highlightedRow == .app(0))
        #expect(results.app(at: .app(0))?.name == "微信")
        #expect(results.app(at: .askAI) == nil)
        #expect(results.app(at: .app(9)) == nil)
        #expect(results.value(of: .app(0)) == nil)
        #expect(results.isEnabled(.app(0)))
        #expect(results.calculation == nil)
    }

    @Test func aQuestionKeepsAskAISelectedInTheFooter() throws {
        let results = try #require(resolve("wechat?"))
        #expect(!results.appsLead)
        #expect(results.rows == [.app(0), .askAI])
        #expect(results.highlightedRow == .askAI)
    }

    @Test func arithmeticBeatsApplications() throws {
        let results = try #require(resolve("1+1"))
        #expect(results.calculation != nil)
        #expect(results.apps.isEmpty)
        #expect(resolve("1+1", calculator: false) == nil, "no app is called 1+1")
        #expect(resolve("zzz") == nil)
        #expect(AskQuickResults.resolve(text: "wx", previous: nil, chinese: true) == nil, "no index, no apps")
    }

    @Test func anUnfinishedExpressionDoesNotKeepApplications() throws {
        let previous = try #require(resolve("wx"))
        #expect(resolve("(", previous: previous) == nil)
    }

    @Test func aChosenApplicationStaysChosenWhileTyping() throws {
        var results = try #require(resolve("t"))
        #expect(results.rows.count >= 2)
        let tablePlus = try #require(results.apps.firstIndex { $0.entry.name == "TablePlus" })
        results.highlight(results.rows.firstIndex(of: .app(tablePlus))!)
        let next = try #require(resolve("ta", previous: results))
        #expect(next.app(at: next.highlightedRow)?.name == "TablePlus")
        #expect(next.chosen)

        var asked = try #require(resolve("wechat?"))
        asked.move(1)
        asked.move(-1)
        let still = try #require(resolve("wechat? ", previous: asked))
        #expect(still.highlightedRow == .askAI)
    }

    @Test func viewMetricsFollowTheRows() throws {
        let one = try #require(resolve("wx"))
        let two = try #require(resolve("wechat?"))
        #expect(AskQuickResultsView.height(for: one) == AskQuickResultsView.height(for: two))
        let bare: CGFloat = 1 + 12 + 42 + 42 + 2 + 2 * (AskQuickResultsView.sectionHeight + AskQuickResultsView.rowSpacing)
        #expect(AskQuickResultsView.height(for: one) == bare)
        #expect(AskQuickResultsView.hint(for: one) == L("ask.quick.hint.app"))
        #expect(AskQuickResultsView.hint(for: two) == L("ask.launcher.hint"))
        #expect(AskQuickResultsView.location(of: URL(fileURLWithPath: "/Applications/WeChat.app")) == "/Applications")
        #expect(AskQuickResultsView.location(of: URL(fileURLWithPath: "/System/Applications/Notes.app")) == L("ask.quick.app.system"))
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tool.app")
        #expect(AskQuickResultsView.location(of: home) == "~/Applications")
    }

    @Test func theSettingDefaultsOn() throws {
        let suite = "ask-apps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askQuickAppSearchEnabled)
        settings.askQuickAppSearchEnabled = false
        #expect(!settings.askQuickAppSearchEnabled)
    }
}
