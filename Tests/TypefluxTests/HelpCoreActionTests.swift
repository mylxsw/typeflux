import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct HelpCoreActionTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "help-core-" + UUID().uuidString))
    }

    @Test func `recording counts each action on its own`() throws {
        let store = HelpCoreActionUsageStore(defaults: try defaults())
        #expect(store.count(.ring) == 0)
        store.record(.ring)
        store.record(.ring)
        store.record(.chat)
        #expect(store.count(.ring) == 2 && store.count(.chat) == 1 && store.count(.launcher) == 0)
    }

    @Test func `counts draw on what was already known about each action`() throws {
        let values = try defaults()
        let stats = UsageStatsStore(defaults: values)
        values.set(5, forKey: "stats.dictationCount")
        values.set(2, forKey: "stats.personaRewriteCount")
        values.set(1, forKey: "stats.editSelectionCount")
        values.set(4, forKey: "stats.askAnswerCount")
        let store = HelpCoreActionUsageStore(defaults: values)
        store.record(.launcher)
        store.record(.chat)
        store.record(.ring)
        #expect(store.counts(keywordUses: 7, stats: stats) == [.voice: 8, .launcher: 8, .ring: 1, .chat: 5])
    }

    @Test func `every action has its words in every language`() {
        for action in HelpCoreAction.allCases {
            #expect(action.steps.count == 3)
            for text in action.steps.flatMap({ [$0.title, $0.detail] }) + [action.tryTitle] {
                #expect(!text.hasPrefix("help."), "\(text)")
            }
            #expect(!action.verb.isEmpty && !action.name.isEmpty)
            #expect(action.scene.key == action.rawValue)
        }
    }

    @Test func `questions and answers have their words`() {
        for question in HelpCatalog.questions {
            #expect(!question.question.hasPrefix("help.") && !question.answer.hasPrefix("help."))
        }
    }

    @Test func `a scene reveals its text from start to end`() {
        #expect(HelpSceneTimeline.revealed("hello", phase: 0).isEmpty)
        #expect(HelpSceneTimeline.revealed("hello", phase: 0.7) == "hello")
        #expect(HelpSceneTimeline.revealed("hello", phase: 1) == "hello")
        #expect(HelpSceneTimeline.revealed("hello", phase: 0.375).count == 3)
        #expect(HelpSceneTimeline.revealed("", phase: 0.5).isEmpty)
        #expect(HelpSceneTimeline.revealed("hi", phase: 0.1, start: 0.5, end: 0.5) == "hi", "no span means all of it")
    }

    @Test func `the ring scene visits its slices and stays in range`() {
        #expect(HelpSceneTimeline.slice(phase: 0, count: 6) == 2)
        #expect(HelpSceneTimeline.slice(phase: 0.3, count: 6) == 3)
        #expect(HelpSceneTimeline.slice(phase: 0.6, count: 6) == 0)
        #expect(HelpSceneTimeline.slice(phase: 1, count: 6) == 4)
        #expect(HelpSceneTimeline.slice(phase: 0, count: 2) == 0)
        #expect(HelpSceneTimeline.slice(phase: 0.5, count: 0) == 0)
        #expect(HelpSceneTimeline.slice(phase: 0.5, count: 6, stops: []) == 0)
    }

    @Test func `shortcut keys light the matching keys of the keyboard`() {
        #expect(HelpKeyboardMap.keyIDs(for: ["⌥", "Space"]) == ["⌥(L)", "Space"])
        #expect(HelpKeyboardMap.keyIDs(for: ["⌥(R)"]) == ["⌥(R)"])
        #expect(HelpKeyboardMap.keyIDs(for: ["⌘(R)", "×2"]) == ["⌘(R)"])
        #expect(HelpKeyboardMap.keyIDs(for: ["⌃", "⌥", "⇧", "⌘", "k"]) == ["⌃(L)", "⌥(L)", "⇧(L)", "⌘(L)", "K"])
        #expect(HelpKeyboardMap.keyIDs(for: ["Fn", "F12", "↩", "/"]) == ["Fn", "F12", "↩", "/"])
        #expect(HelpKeyboardMap.keyIDs(for: ["Tab", "Esc"]) == ["⇥", "esc"])
        #expect(HelpKeyboardMap.keyIDs(for: ["no such key"]).isEmpty)
        #expect(HelpKeyboardMap.keyIDs(for: []).isEmpty)
        let ids = HelpKeyboardMap.rows.joined().map(\.id)
        #expect(Set(ids).count == ids.count, "the drawing's keys must be unique for its identity")
    }

    @Test func `the ring and launcher use configured keys and chat teaches its keyword`() {
        var input = HelpCatalogInput(keywords: [], builtInHotkeys: [:], actionHotkeys: [:], keywordHotkeys: [],
                                     usage: [:])
        input.actionHotkeys[.ring] = HelpCatalogTests.controlOptionR
        input.builtInHotkeys[.ask] = HelpCatalogTests.controlOptionR
        let catalog = HelpCatalog.build(input)
        #expect(catalog.keys(for: .ring) == ["⌃", "⌥", "R"] && catalog.keys(for: .launcher) == ["⌃", "⌥", "R"])
        #expect(catalog.keys(for: .voice) == nil, "an unset voice key stays unset")
        #expect(catalog.keys(for: .chat) == ["chat"])
    }

    @Test func `shortcut contexts cover every window once`() {
        let contexts = HelpShortcutContext.all
        #expect(Set(contexts).count == contexts.count)
        let windows = HelpShortcutSection.allCases.filter { $0 != .global && $0 != .keyword }
        for window in windows {
            #expect(contexts.contains(.section(window)), "\(window.rawValue) has no place in the list")
            #expect(HelpShortcutContext(window) == .section(window))
        }
        #expect(HelpShortcutContext(.global) == nil && HelpShortcutContext(.keyword) == nil)
        #expect(contexts.contains(.commands))
        #expect(!HelpShortcutContext.commands.title.hasPrefix("help."))
    }

    @Test func `searches mark the match and leave other text alone`() {
        let marked = HelpSearch.highlighted("Open Settings", matching: " SETTINGS ")
        let runs = marked.runs.map { String(marked[$0.range].characters) }
        #expect(runs == ["Open ", "Settings"], "the match is a run of its own")
        for query in [nil, "", "  ", "nothing"] as [String?] {
            #expect(HelpSearch.highlighted("Open Settings", matching: query).runs.count == 1)
        }
    }

    @Test func `set shortcuts come first, keyword shortcuts among them`() {
        let keyword = HelpShortcut(id: "k", section: .keyword, title: "k", detail: "", keys: ["⌘", "K"])
        let unset = HelpShortcut(id: "u", section: .global, title: "u", detail: "")
        let set = HelpShortcut(id: "s", section: .global, title: "s", detail: "", keys: ["⌥"])
        let window = HelpShortcut(id: "w", section: .chat, title: "w", detail: "", keys: ["↩"])
        let catalog = HelpCatalog(shortcuts: [unset, set, keyword, window])
        #expect(catalog.shortcutCards.map(\.id) == ["s", "k", "u"])
    }

    @Test func `global shortcuts have a symbol for every target`() {
        let shortcuts = HelpCatalog.globalShortcuts(HelpCatalogInput(keywords: [], builtInHotkeys: [:],
                                                                     actionHotkeys: [:], keywordHotkeys: [], usage: [:]))
        #expect(shortcuts.allSatisfy { $0.symbol != "keyboard" })
        #expect(HelpShortcut(id: "x", section: .launcher, title: "", detail: "").symbol == "keyboard")
    }
}
