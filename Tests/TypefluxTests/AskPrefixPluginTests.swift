import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskPrefixPluginTests {
    private func entry(_ word: String, title: String = "Feature", detail: String = "",
                       enabled: Bool = true) -> AskPrefixPlugin.Entry {
        .init(keyword: AskKeyword(keyword: word, pluginID: "test", enabled: enabled),
              title: title, detail: detail, symbol: "star")
    }

    @Test func `search ranks exact then starts then contains and keeps disabled last`() {
        let entries = [entry("afy"), entry("fyja"), entry("fy"), entry("alias", title: "翻译", detail: "Japanese"),
                       entry("FY", enabled: false), entry("workflow", title: "My workflow")]
        #expect(AskPrefixPlugin.filter(entries, query: "  FY \n").map(\.keyword.keyword) == ["fy", "fyja", "afy", "FY"])
        #expect(AskPrefixPlugin.filter(entries, query: "翻译").map(\.keyword.keyword) == ["alias"])
        #expect(AskPrefixPlugin.filter(entries, query: "japan").map(\.keyword.keyword) == ["alias"])
        #expect(AskPrefixPlugin.filter(entries, query: "my work").map(\.keyword.keyword) == ["workflow"])
        #expect(AskPrefixPlugin.filter(entries, query: "missing").isEmpty)
        #expect(AskPrefixPlugin.filter(entries, query: " ").map(\.keyword.keyword)
            == ["afy", "fyja", "fy", "alias", "workflow", "FY"])
    }

    @Test func `output lists aliases and only offers entry for available rows`() async throws {
        let rows = [entry("fy", title: "Translate"), entry("tr", title: "Translate"), entry("off", enabled: false),
                    AskPrefixPlugin.Entry(keyword: .init(keyword: "conflict", pluginID: "workflow.x"),
                                          title: "Conflict", symbol: "star", unavailableReason: "Unavailable")]
        let plugin = AskPrefixPlugin(entries: { _ in rows })
        let request = AskPluginRequest(text: "", origin: .argument, keyword: plugin.defaultKeywords[0],
                                       options: [:], interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        #expect(plan.mode == .live && plan.debounce == .zero)
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        let output = try await plugin.run(request, plan: plan)
        #expect(output.items.map(\.title) == ["fy", "tr", "off", "conflict"])
        #expect(output.items[0].actions.first?.kind == .enterKeyword("fy"))
        #expect(output.items[1].actions.first?.kind == .enterKeyword("tr"))
        #expect(!output.items[2].valid && output.items[2].actions.isEmpty)
        #expect(!output.items[3].valid && output.items[3].actions.isEmpty)
        #expect(output.items[2].subtitle.contains(L("ask.plugin.prefix.disabled")))
        #expect(Set(output.items.map(\.id)).count == rows.count)
        var missing = request
        missing.text = "unknown"
        let empty = try await plugin.run(missing, plan: plan)
        #expect(empty.items.isEmpty && empty.body == L("ask.plugin.prefix.noMatch", "unknown"))
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
        #expect(plugin.chipDetail(for: request.keyword, language: .english) == nil)
    }

    @Test func `captured selection never filters the directory and provider is read on each run`() async throws {
        var rows = [entry("one"), entry("two")]
        let plugin = AskPrefixPlugin(entries: { _ in rows })
        let session = AskPluginSession(plugins: [plugin]) { plugin.defaultKeywords }
        session.enter(plugin.defaultKeywords[0])
        session.update(text: "", selection: "unknown selected text", language: .english)
        try await AskQuickSearchSessionTests.wait { session.output != nil }
        #expect(session.output?.items.map(\.title) == ["one", "two"])
        #expect(session.request?.origin == .argument && session.request?.selection == nil)
        rows = [entry("two")]
        session.update(text: "two", selection: "other selection", language: .english)
        try await AskQuickSearchSessionTests.wait { session.output?.original == "two" }
        #expect(session.output?.items.map(\.title) == ["two"])
        session.deactivate()
    }

    @Test func `upgrade adds directory without replacing custom or workflow names`() {
        let previousGroups = AskPluginRegistry.coveredGroups.filter { $0 != AskPrefixPlugin.id }
        let saved = AskPluginRegistry.defaultKeywords.filter { $0.pluginID != AskPrefixPlugin.id }
        #expect(AskPluginRegistry.keywords(saved: saved, known: previousGroups) == saved + AskPluginRegistry
            .defaultKeywords.filter { $0.pluginID == AskPrefixPlugin.id })
        let custom = AskKeyword(keyword: "PREFIX", pluginID: AskPromptPlugin.id, options: ["prompt": "Say {input}"])
        let merged = AskPluginRegistry.keywords(saved: saved + [custom], known: previousGroups)
        #expect(merged.contains(custom) && !merged
            .contains { $0.pluginID == AskPrefixPlugin.id && $0.contains("prefix") })
        #expect(!AskPluginRegistry.keywords(saved: saved, known: previousGroups, reserved: ["prefix"])
            .contains { $0.pluginID == AskPrefixPlugin.id && $0.contains("prefix") })
        #expect(!AskPluginRegistry.keywords(saved: nil, known: nil, reserved: ["prefix"])
            .contains { $0.pluginID == AskPrefixPlugin.id && $0.contains("prefix") })
        #expect(AskPluginRegistry.keywords(saved: [], known: AskPluginRegistry.coveredGroups).isEmpty)
        #expect(AskKeywordMatcher.match("prefixmore", keywords: AskPrefixPlugin.keywords) == nil)
        #expect(AskKeywordMatcher.match("/prefix", keywords: AskPrefixPlugin.keywords) == nil)
    }

    @Test func `directory reflects renames presets and disabled workflows`() throws {
        let f = try AskTestFixture()
        let wf = try AskWorkflowFixture()
        try wf.write(
            "local.enabled",
            manifest: AskWorkflowFixture.inline("local.enabled", keyword: "work", script: "echo hello",
                                                extra: [
                                                    "name": "Work search",
                                                    "description": "Projects"
                                                ])
        )
        try wf.write(
            "local.disabled",
            manifest: AskWorkflowFixture.inline("local.disabled", keyword: "off", script: "echo bye")
        )
        wf.store.reload()
        wf.store.trust("local.enabled")
        wf.store.trust("local.disabled")
        wf.store.setEnabled("local.disabled", false)
        f.model.workflows = wf.store
        let custom = AskKeyword(keyword: "fyja", pluginID: AskTranslatePlugin.id, options: ["target": "ja"])
        f.model.modelLibrary.settings.saveAskLauncherKeywords([custom] + AskPrefixPlugin.keywords)
        let entries = f.model.launcherKeywordDirectory(language: .english)
        #expect(entries.map(\.keyword.keyword).sorted() == ["fyja", "off", "prefix", "work"])
        #expect(entries.first { $0.keyword.keyword == "fyja" }?.title.contains(AskTranslationLanguages.name(
            "ja",
            in: .english
        )) == true)
        #expect(entries.first { $0.keyword.keyword == "work" }?.title == "Work search")
        #expect(entries.first { $0.keyword.keyword == "work" }?.canEnter == true)
        #expect(entries.first { $0.keyword.keyword == "off" }?.canEnter == false)
        #expect(AskPrefixPlugin.filter(entries, query: "projects").map(\.keyword.keyword) == ["work"])
        var renamed = custom
        renamed.keyword = "jp"
        f.model.modelLibrary.settings.saveAskLauncherKeywords([renamed] + AskPrefixPlugin.keywords)
        #expect(f.model.launcherKeywordDirectory(language: .english).contains { $0.keyword.keyword == "jp" })
        #expect(!f.model.launcherKeywordDirectory(language: .english).contains { $0.keyword.keyword == "fyja" })
    }

    @Test func `existing workflow keeps prefix and directory can use A custom alias`() throws {
        let f = try AskTestFixture()
        let wf = try AskWorkflowFixture()
        try wf.write(
            "local.prefix",
            manifest: AskWorkflowFixture.inline("local.prefix", keyword: "prefix", script: "echo hi")
        )
        wf.store.reload()
        wf.store.trust("local.prefix")
        f.model.workflows = wf.store
        #expect(f.model.launcherKeywords.first { $0.id == "prefix" }?.pluginID == "workflow.local.prefix")
        #expect(!f.model.launcherKeywords.contains { $0.pluginID == AskPrefixPlugin.id && $0.contains("prefix") })
        f.model.launcherDraft.text = "prefix"
        #expect(!f.model.enterKeywordDirectoryFromLauncher())
        let alias = AskKeyword(keyword: "keywords", pluginID: AskPrefixPlugin.id)
        f.model.modelLibrary.settings.saveAskLauncherKeywords([alias])
        #expect(f.model.launcherKeywords.contains(alias))
        #expect(f.model.launcherKeywords.contains { $0.id == "prefix" && $0.pluginID == "workflow.local.prefix" })
        let draft = AskKeywordDraft(editing: alias)
        #expect(draft.kind == .prefix && draft.fieldProblem == nil && draft.result() == alias)
        #expect(draft.displayName == L("ask.plugin.prefix.title"))
    }

    @Test func `entering from directory waits and revalidates disabled or missing targets`() async throws {
        let f = try AskTestFixture()
        let target = AskTestPlugin()
        target.noInput = true
        let directory = AskPrefixPlugin(entries: { _ in [] })
        f.model
            .plugins = AskPluginSession(plugins: [directory, target]) {
                directory.defaultKeywords + target.defaultKeywords
            }
        f.model.launcherDraft = AskDraft(text: "prefix tt", selection: "Selected text")
        #expect(f.model.enterKeywordDirectoryFromLauncher())
        let action = AskPluginAction(kind: .enterKeyword("tt"), title: "Enter", symbol: "arrow.right", shortcut: .enter)
        #expect(f.model.performPluginAction(action) == .stay)
        #expect(f.model.plugins.keyword?.keyword == "tt" && f.model.launcherDraft.text.isEmpty)
        f.model.plugins.update(text: "", selection: "Selected text", language: .english)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.model.plugins.phase == .waiting && target.runs.isEmpty)
        f.model.plugins.update(text: "", selection: "Selected text", language: .english, runWhenPlanned: true)
        try await AskQuickSearchSessionTests.wait { f.model.plugins.output != nil }
        #expect(target.runs.count == 1 && target.runs[0].text == "Selected text")
        #expect(f.model.performPluginAction(.init(kind: .enterKeyword("missing"), title: "", symbol: "")) == .stay)
        #expect(f.model.plugins.keyword?.keyword == "tt")
        var disabled = target.defaultKeywords[0]
        disabled.enabled = false
        f.model.plugins = AskPluginSession(plugins: [directory, target]) { directory.defaultKeywords + [disabled] }
        f.model.plugins.enter(directory.defaultKeywords[0])
        _ = f.model.performPluginAction(action)
        #expect(f.model.plugins.keyword?.pluginID == AskPrefixPlugin.id)
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
    }

    @Test func `entering live target runs only after typing`() async throws {
        let target = AskTestPlugin()
        target.noInput = true
        let session = AskPluginSession(plugins: [target]) { target.defaultKeywords }
        session.debounce = .zero
        session.enter(target.defaultKeywords[0], waitingForInput: true)
        session.update(text: "", selection: nil, language: .english)
        try await Task.sleep(for: .milliseconds(20))
        #expect(target.runs.isEmpty && session.phase == .waiting)
        session.update(text: "typed", selection: "Selected", language: .english)
        try await AskQuickSearchSessionTests.wait { session.output != nil }
        #expect(target.runs.first?.text == "typed" && target.runs.first?.origin == .argument)
        session.deactivate()
    }
}
