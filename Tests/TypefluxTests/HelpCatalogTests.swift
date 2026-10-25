import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct HelpCatalogTests {
    static let controlOptionR = HotkeyBinding(
        keyCode: 15, modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )
    static let translate = AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id, aliases: ["tr"])
    static let polish = AskKeyword(keyword: "rw", pluginID: AskPromptPlugin.id, options: ["preset": "polish"])
    static let summarize = AskKeyword(keyword: "sum", pluginID: AskPromptPlugin.id, options: ["preset": "summarize"])
    static let japanese = AskKeyword(keyword: "fyja", pluginID: AskTranslatePlugin.id, options: ["target": "ja"])
    static let workflow = AskKeyword(keyword: "ip", pluginID: AskWorkflowPlugin.idPrefix + "local.ip")
    static let lock = AskKeyword(keyword: "lockscreen", pluginID: AskSystemCommand.lockScreen.id)
    static let help = AskHelpPlugin.keywords[0]
    static let files = AskKeyword(keyword: "f", pluginID: AskFileSearchPlugin.id)
    static let shot = AskKeyword(keyword: "jt", pluginID: AskScreenshotPlugin.id, options: ["mode": "region"])

    static func source(_ keyword: AskKeyword, unavailable: String? = nil, selection: Bool = false) -> HelpKeywordSource {
        HelpKeywordSource(entry: AskPrefixPlugin.Entry(keyword: keyword, title: keyword.keyword.uppercased(),
                                                       detail: "about " + keyword.keyword, symbol: "circle",
                                                       unavailableReason: unavailable),
                          usesSelection: selection)
    }

    static let defaults = [translate, polish, summarize, lock, help, files, shot]

    static func input(keywords: [AskKeyword] = [translate, polish, summarize, japanese, workflow, lock, help, files, shot],
                      builtIns: [BuiltInHotkey: HotkeyBinding] = [.activation: .defaultActivation, .ask: .defaultAsk],
                      actions: [AppHotkeyAction: HotkeyBinding] = [:],
                      keywordHotkeys: [KeywordHotkey] = [],
                      usage: [String: Int] = ["fy": 4]) -> HelpCatalogInput {
        HelpCatalogInput(keywords: keywords.map { source($0, selection: $0.pluginID == AskTranslatePlugin.id) },
                         defaultKeywords: defaults, builtInHotkeys: builtIns, actionHotkeys: actions,
                         keywordHotkeys: keywordHotkeys, usage: usage)
    }

    @Test func `keywords are grouped by use and the user's own keywords are theirs`() {
        let catalog = HelpCatalog.build(Self.input())
        func group(_ keyword: AskKeyword) -> HelpKeywordGroup? {
            catalog.keywords.first { $0.keyword == keyword }?.group
        }
        #expect(group(Self.translate) == .text)
        #expect(group(Self.polish) == .text)
        #expect(group(Self.files) == .search)
        #expect(group(Self.shot) == .capture)
        #expect(group(Self.help) == .tools)
        #expect(group(Self.lock) == .system)
        #expect(group(Self.workflow) == .mine)
        #expect(group(Self.japanese) == .mine, "a keyword with options of its own was made by the user")
        let japanese = catalog.keywords.first { $0.keyword == Self.japanese }
        #expect(japanese?.isBuiltIn == false && japanese?.origin == L("help.keyword.origin.custom"))
        #expect(catalog.keywords.first { $0.keyword == Self.workflow }?.origin == L("help.keyword.origin.workflow"))
        #expect(catalog.keywords.first { $0.keyword == Self.lock }?.origin == L("help.keyword.origin.system"))
        #expect(catalog.keywords(in: .text).map(\.keyword.keyword) == ["fy", "rw", "sum"])
        #expect(catalog.keyword(id: AskTranslatePlugin.id + ":fy")?.usageCount == 4)
        #expect(catalog.keyword(id: "missing") == nil)
    }

    @Test func `keyword shows the keys of an active keyword shortcut only`() {
        let active = KeywordHotkey(binding: Self.controlOptionR, keyword: "rw", pluginID: AskPromptPlugin.id)
        var off = KeywordHotkey(binding: Self.controlOptionR, keyword: "sum", pluginID: AskPromptPlugin.id)
        off.enabled = false
        let catalog = HelpCatalog.build(Self.input(keywordHotkeys: [active, off]))
        #expect(catalog.keywords.first { $0.keyword == Self.polish }?.shortcut == ["⌃", "⌥", "R"])
        #expect(catalog.keywords.first { $0.keyword == Self.summarize }?.shortcut == nil)
        let rows = catalog.shortcuts(in: .keyword)
        #expect(rows.count == 2)
        #expect(rows[0].title == "RW" && rows[0].keys == ["⌃", "⌥", "R"] && rows[0].target == .keyword(active.id))
        #expect(rows[1].detail == L("help.shortcuts.keyword.off"))
    }

    @Test func `keyword shortcut rows explain a missing or switched off keyword and include unset ones`() {
        var disabled = Self.polish
        disabled.enabled = false
        let missing = KeywordHotkey(binding: Self.controlOptionR, keyword: "gone", pluginID: AskPromptPlugin.id)
        let paused = KeywordHotkey(binding: Self.controlOptionR, keyword: "rw", pluginID: AskPromptPlugin.id)
        let unset = KeywordHotkey(binding: nil, keyword: "fy", pluginID: AskTranslatePlugin.id)
        let catalog = HelpCatalog.build(Self.input(keywords: [Self.translate, disabled],
                                                   keywordHotkeys: [missing, paused, unset]))
        let rows = catalog.shortcuts(in: .keyword)
        #expect(rows.map(\.title) == ["gone", "RW", "FY"])
        #expect(rows[2].keys == nil && rows[2].detail == L("help.shortcuts.unset"))
        #expect(rows[0].detail == L("help.shortcuts.keyword.missing", "gone"))
        #expect(rows[1].detail == L("help.keyword.disabled"))
        let shown = catalog.keywords.first { $0.keyword == disabled }
        #expect(shown?.isAvailable == false && shown?.statusText == L("help.keyword.disabled"))
    }

    @Test func `global shortcuts follow the user's bindings and list unset features`() {
        let flags = UInt(NSEvent.ModifierFlags.command.union(.shift).rawValue)
        let custom = HotkeyBinding(keyCode: 4, modifierFlags: flags)
        let catalog = HelpCatalog.build(Self.input(builtIns: [.activation: .rightCommandActivation, .ask: custom],
                                                   actions: [.openHelp: Self.controlOptionR]))
        let global = catalog.shortcuts(in: .global)
        #expect(global.count == BuiltInHotkey.allCases.count + AppHotkeyAction.allCases.count)
        #expect(global.first { $0.target == .builtIn(.ask) }?.keys == ["⇧", "⌘", "H"])
        #expect(global.first { $0.target == .builtIn(.persona) }?.keys == nil, "a removed shortcut shows as unset")
        #expect(global.first { $0.target == .action(.openHelp) }?.keys == ["⌃", "⌥", "R"])
        #expect(global.first { $0.target == .action(.openChat) }?.keys == nil)
        #expect(catalog.voiceKeys == ["⌘(R)"])
        #expect(catalog.launcherKeys == ["⇧", "⌘", "H"])
        #expect(HelpCatalog.build(Self.input(builtIns: [:])).launcherKeys == nil)
    }

    @Test func `a double press shows its count as a key`() {
        var binding = HotkeyBinding.defaultActivation
        binding.pressCount = 2
        #expect(HelpKeys.keys(binding) == ["Fn", "×2"])
    }

    @Test func `untried keywords are built in, available, unused and useful`() {
        let unavailable = Self.source(Self.files, unavailable: "No index")
        var input = Self.input(usage: ["fy": 1, "rw": 3])
        input.keywords[input.keywords.firstIndex { $0.entry.keyword == Self.files }!] = unavailable
        let catalog = HelpCatalog.build(input)
        #expect(catalog.untriedKeywords().map(\.keyword.keyword) == ["sum", "jt"])
        #expect(catalog.untriedKeywords(limit: 1).map(\.keyword.keyword) == ["sum"])
    }

    @Test func `fixed keys and commands are complete and unique`() {
        let catalog = HelpCatalog.build(Self.input())
        let fixed = HelpCatalog.fixedShortcuts
        #expect(Set(fixed.map(\.id)).count == fixed.count)
        #expect(fixed.allSatisfy { $0.keys?.isEmpty == false && !$0.title.hasPrefix("help.") })
        #expect(catalog.shortcuts(in: .launcher).contains { $0.keys == ["⌘", "K"] })
        #expect(catalog.shortcuts(in: .chat).contains { $0.keys == ["⇧", "↩"] })
        #expect(catalog.commands.map(\.name).contains("/help"))
        #expect(catalog.commands.allSatisfy { $0.name.hasPrefix("/") && !$0.title.isEmpty })
        #expect(Set(catalog.questions.map(\.id)).count == catalog.questions.count)
        #expect(catalog.questions.allSatisfy { !$0.question.hasPrefix("help.") && !$0.answer.hasPrefix("help.") })
    }

    @Test func `reference covers feature sections and current contextual keys in every language`() {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            let fixed = HelpCatalog.fixedShortcuts
            #expect(Set(fixed.map(\.id)).count == fixed.count)
            #expect(fixed.allSatisfy { !$0.title.isEmpty && !$0.title.hasPrefix("help.") && !$0.title.contains("%@") })
            for section in HelpShortcutSection.allCases where ![.global, .keyword].contains(section) {
                #expect(fixed.contains { $0.section == section })
                #expect(!section.title.hasPrefix("help."))
            }
            #expect(fixed.first { $0.id == "chat.newLocal" }?.keys == ["⌘", "⇧", "N"])
            #expect(fixed.first { $0.id == "notes.split" }?.keys == ["⌘", "⌥", "E"])
            #expect(!fixed.contains { $0.id == "chat.settings" })
            for tool in ScreenshotAnnotationTool.allCases {
                #expect(fixed.first { $0.id == "screenshot.tool." + tool.rawValue }?.keys == [tool.shortcut])
            }
        }
    }

    @Test func `search finds unassigned features contexts and numbered key ranges`() {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        AppLocalization.shared.setLanguage(.english)
        let catalog = HelpCatalog.build(Self.input(builtIns: [:]))
        let unset = catalog.shortcuts.first { $0.target == .builtIn(.persona) }!
        #expect(HelpSearch.search(unset.title, in: catalog).shortcuts.contains(unset))
        #expect(HelpSearch.search("cmd 3", in: catalog).shortcuts.contains { $0.id == "launcher.number" })
        #expect(!HelpSearch.search("cmd 9", in: catalog).shortcuts.contains { $0.id == "monitor.number" })
        #expect(HelpSearch.search("shift tab", in: catalog).shortcuts.contains { $0.id == "worldClock.meeting" })
        #expect(HelpSearch.search(HelpShortcutSection.clipboard.title, in: catalog).shortcuts
            .filter { $0.section == .clipboard }.count == catalog.shortcuts(in: .clipboard).count)
    }

    @Test func `fixed key titles follow the interface language`() {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        AppLocalization.shared.setLanguage(.english)
        let english = HelpCatalog.fixedShortcuts.map(\.title)
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let chinese = HelpCatalog.fixedShortcuts.map(\.title)
        #expect(english != chinese)
        #expect(chinese.first == L("help.key.launcher.send"))
    }

    @Test func `pages and groups have titles`() {
        for page in HelpPage.allCases {
            #expect(!page.title.hasPrefix("help.") && !page.subtitle.hasPrefix("help.") && !page.symbol.isEmpty)
        }
        for group in HelpKeywordGroup.allCases { #expect(!group.title.hasPrefix("help.")) }
        for section in HelpShortcutSection.allCases { #expect(!section.title.hasPrefix("help.")) }
    }

    @Test func `the catalog reads every shortcut from settings`() throws {
        let defaults = try #require(UserDefaults(suiteName: "help-catalog-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        settings.setHotkey(nil, for: .persona)
        settings.setHotkey(Self.controlOptionR, for: .openNotes)
        settings.keywordHotkeys = [
            KeywordHotkey(binding: Self.controlOptionR, keyword: "fy", pluginID: AskTranslatePlugin.id)
        ]
        let input = HelpCatalogInput(keywords: [Self.source(Self.translate)], settings: settings, usage: [:])
        #expect(input.builtInHotkeys[.persona] == nil)
        #expect(input.builtInHotkeys[.activation] == settings.activationHotkey)
        #expect(input.actionHotkeys[.openNotes] == Self.controlOptionR)
        #expect(input.keywordHotkeys.count == 1)
        #expect(HelpCatalog.build(input).keywords.first?.shortcut == ["⌃", "⌥", "R"])
    }
}

@Suite(.exclusiveUIState)
@MainActor
struct HelpSearchTests {
    var catalog: HelpCatalog {
        HelpCatalog.build(HelpCatalogTests.input(actions: [.openHelp: HelpCatalogTests.controlOptionR]))
    }

    @Test func `spoken key names become keys in any order`() {
        #expect(HelpSearch.keyTokens("cmd k") == ["⌘", "k"])
        #expect(HelpSearch.keyTokens("⌘K") == ["⌘", "k"])
        #expect(HelpSearch.keyTokens("shift+enter") == ["⇧", "↩"])
        #expect(HelpSearch.keyTokens("Command Option A") == ["⌘", "⌥", "a"])
        #expect(HelpSearch.keyTokens("fn") == ["fn"])
        #expect(HelpSearch.keyTokens("tab") == nil, "a lone key name may be a keyword")
        #expect(HelpSearch.keyTokens("alternative") == nil)
        #expect(HelpSearch.keyTokens("翻译") == nil)
        #expect(HelpSearch.keyTokens("cmd ab") == nil, "two plain keys are text")
    }

    @Test func `a key query finds shortcuts only`() {
        let results = HelpSearch.search("cmd k", in: catalog)
        #expect(!results.shortcuts.isEmpty && results.shortcuts.allSatisfy { $0.keys?.contains("K") == true })
        #expect(results.keywords.isEmpty && results.commands.isEmpty && results.questions.isEmpty)
        let reversed = HelpSearch.search("opt ctrl r", in: catalog)
        #expect(reversed.shortcuts.contains { $0.target == .action(.openHelp) })
    }

    @Test func `text finds keywords by word alias title and detail`() {
        #expect(HelpSearch.search("tr", in: catalog).keywords.map(\.keyword.keyword).contains("fy"))
        #expect(HelpSearch.search("FYJA", in: catalog).keywords.map(\.keyword.keyword) == ["fyja"])
        #expect(HelpSearch.search("about ip", in: catalog).keywords.map(\.keyword.keyword) == ["ip"])
        #expect(HelpSearch.search("tab", in: catalog).keywords.isEmpty)
        #expect(HelpSearch.folded("  Google   搜索 ") == "google 搜索")
        #expect(HelpSearch.search("fy", in: catalog).questions.allSatisfy {
            HelpSearch.folded($0.question + " " + $0.answer).contains("fy")
        }, "words are not glued together across spaces")
        #expect(HelpSearch.search("/help", in: catalog).commands.map(\.name) == ["/help"])
    }

    @Test func `questions are searched by question and answer and empty queries find nothing`() throws {
        let question = try #require(catalog.questions.first)
        #expect(HelpSearch.search(question.question, in: catalog).questions.contains(question))
        #expect(HelpSearch.search("   ", in: catalog).isEmpty)
        let none = HelpSearch.search("zzzz-nothing", in: catalog)
        #expect(none.isEmpty && none.count == 0)
    }
}
