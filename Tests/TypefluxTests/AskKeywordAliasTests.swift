import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
struct AskKeywordAliasTests {
    @Test func `legacy data decodes and new data round trips`() throws {
        let legacy = Data(#"{"keyword":"fy","pluginID":"translate","options":{},"enabled":false}"#.utf8)
        let old = try JSONDecoder().decode(AskKeyword.self, from: legacy)
        #expect(old.aliases.isEmpty && !old.enabled)
        let entry = AskKeyword(keyword: "fy", pluginID: "translate", aliases: ["translate", "翻译"])
        #expect(try JSONDecoder().decode(AskKeyword.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test func `every alias matches with the same options and identity`() {
        let entry = AskKeyword(
            keyword: "f",
            pluginID: "files",
            options: ["mode": "test"],
            aliases: ["filesearch", "文件"]
        )
        for word in entry.allKeywords {
            #expect(AskKeywordMatcher.match(word.uppercased(), keywords: [entry]) == .hint(entry))
            #expect(AskKeywordMatcher.match(word + ":hello", keywords: [entry]) == .active(entry, argument: "hello"))
            #expect(AskKeywordMatcher.match(word + "extra hello", keywords: [entry]) == nil)
        }
        var disabled = entry
        disabled.enabled = false
        #expect(AskKeywordMatcher.match("filesearch hi", keywords: [disabled]) == nil)
        let longer = AskKeyword(keyword: "filesearchmore", pluginID: "other")
        #expect(AskKeywordMatcher.match("filesearchmore hi", keywords: [entry, longer]) == .active(
            longer,
            argument: "hi"
        ))
    }

    @Test func `legacy rows merge without losing different options or enabled states`() {
        let first = AskKeyword(keyword: "fy", pluginID: "translate")
        let second = AskKeyword(keyword: "tr", pluginID: "translate", aliases: ["翻译"])
        let target = AskKeyword(keyword: "ja", pluginID: "translate", options: ["target": "ja"])
        let disabled = AskKeyword(keyword: "off", pluginID: "translate", enabled: false)
        let merged = AskKeywordAliases.consolidate([first, second, target, disabled])
        #expect(merged.count == 3)
        #expect(merged[0].allKeywords == ["fy", "tr", "翻译"])
        #expect(merged[1] == target && merged[2] == disabled)
        #expect(AskKeywordAliases.consolidate(merged) == merged)
    }

    @Test func `migration adds english names once and respects reserved aliases`() {
        let legacy = AskTranslatePlugin.keywords
        let oldGroups = AskPluginRegistry.coveredGroups.filter { $0 != AskPluginRegistry.aliasKeywords }
        let upgraded = AskPluginRegistry.keywords(saved: legacy, known: oldGroups)
        #expect(upgraded.count == 2 + AskSystemCommand.allCases.count)
        #expect(upgraded[0].allKeywords == ["fy", "tr", "翻译", "translate"])
        #expect(upgraded[1].allKeywords == ["dict", "词典", "dictionary"])
        #expect(AskPluginRegistry.keywords(saved: upgraded, known: AskPluginRegistry.coveredGroups) == upgraded)
        let reserved = AskPluginRegistry.keywords(saved: legacy, known: oldGroups, reserved: ["translate"])
        #expect(!reserved.contains { $0.contains("translate") })
        let owner = AskKeyword(keyword: "custom", pluginID: "web", aliases: ["translate"])
        let conflict = AskPluginRegistry.keywords(saved: legacy + [owner], known: oldGroups)
        #expect(!conflict[0].contains("translate") && conflict.contains(owner))
        var removed = upgraded
        removed[0].aliases.removeAll { $0 == "translate" }
        #expect(AskPluginRegistry.keywords(saved: removed, known: AskPluginRegistry.coveredGroups) == removed)
    }

    @Test func `migration keeps disabled commands off and adds their english alias`() {
        let oldGroups = AskPluginRegistry.coveredGroups.filter { $0 != AskPluginRegistry.aliasKeywords }
        let custom = AskKeyword(keyword: "lock", pluginID: AskSystemCommand.lockScreen.id, enabled: false)
        let migrated = AskPluginRegistry.keywords(saved: [custom], known: oldGroups)
        let command = migrated.filter { $0.pluginID == custom.pluginID }
        #expect(command.count == 1 && command.first?.enabled == false)
        #expect(command.first?.contains("lockscreen") == true)
        #expect(AskKeywordMatcher.match("lockscreen ", keywords: migrated) == nil)
    }

    @Test func `existing builtin words keep their precedence over workflows`() {
        let entries = AskPluginRegistry.keywords(saved: nil, known: nil, reserved: ["fy", "translate", "filesearch"])
        #expect(entries.contains { $0.pluginID == AskTranslatePlugin.id && $0.contains("fy") })
        #expect(!entries.contains { $0.contains("translate") || $0.contains("filesearch") })
    }

    @Test func `editor validates all words and keeps their order`() {
        var draft = AskKeywordDraft(adding: .files)
        draft.keyword = "ff"
        draft.aliases = [" findfiles ", "文件"]
        #expect(draft.canSave(among: [], workflows: []))
        #expect(draft.result().allKeywords == ["ff", "findfiles", "文件"])
        draft.aliases.append("FF")
        #expect(!draft.canSave(among: [], workflows: []))
        draft.aliases = [""]
        #expect(!draft.canSave(among: [], workflows: []))
        draft.aliases = ["used"]
        #expect(!draft.canSave(among: [.init(keyword: "main", pluginID: "web", aliases: ["USED"])], workflows: []))
        #expect(!draft.canSave(
            among: [],
            workflows: [.init(keyword: "used", workflowID: "x", workflowName: "X", enabled: false)]
        ))
        draft.aliases = [String(repeating: "x", count: AskKeywordMatcher.maximumLength + 1)]
        #expect(!draft.canSave(among: [], workflows: []))
    }

    @Test func `searches find aliases across settings directory and launcher`() {
        let entry = AskKeyword(keyword: "ff", pluginID: AskFileSearchPlugin.id, aliases: ["findfiles"])
        let rows = AskKeywordListPresentation.rows(keywords: [entry], interface: .english, secondLanguage: "en")
        #expect(AskKeywordListPresentation.filter(rows, kind: nil, query: "  FINDFILES ").count == 1)
        let directory = AskPrefixPlugin.Entry(keyword: entry, title: "Files", symbol: "doc")
        #expect(AskPrefixPlugin.filter([directory], query: "findfiles") == [directory])
        let feature = AskLauncherSearchEntry(keyword: entry, title: "Files", detail: "", symbol: "doc")
        #expect(AskLauncherSearchEntry.search([feature], text: "findfiles") == [feature])
    }

    @Test func `sections cover related capabilities`() {
        #expect(AskKeywordSection.search.kinds == [.web, .files, .tabs, .bookmarks])
        #expect(AskKeywordSection.typeflux.kinds == [.chat, .prefix, .setting, .history])
        #expect(AskKeywordSection.allCases.flatMap(\.kinds).count == AskKeywordKind.editableKinds.count)
    }

    @MainActor @Test func `workflows cannot claim an alias`() throws {
        let fixture = try AskWorkflowFixture()
        let builtin = AskKeyword(keyword: "ff", pluginID: AskFileSearchPlugin.id, aliases: ["findfiles"])
        #expect(fixture.store.keywordProblem("FINDFILES", builtIn: [builtin]) != nil)
        try fixture.write(
            "conflict",
            manifest: AskWorkflowFixture.inline("conflict", keyword: "findfiles", script: "echo")
        )
        fixture.store.reload()
        fixture.store.trust("conflict")
        let result = AskWorkflowStore.keywords(of: fixture.store.plugins(source: { (nil, nil) }), excluding: [builtin])
        #expect(result.keywords.isEmpty && result.conflicts.count == 1)
    }
}
