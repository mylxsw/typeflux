import Foundation
import Testing
@testable import Typeflux

@Suite("Launcher keyword list")
struct AskKeywordListPresentationTests {
    private let workflows = [
        AskWorkflowKeywordEntry(keyword: "wf", workflowID: "local.python", workflowName: "Python", enabled: true),
        AskWorkflowKeywordEntry(keyword: "FY", workflowID: "local.clash", workflowName: "Clash", enabled: true)
    ]

    private func rows(_ keywords: [AskKeyword] = AskPluginRegistry.defaultKeywords) -> [AskKeywordListRow] {
        AskKeywordListPresentation.rows(keywords: keywords, workflows: workflows, interface: .english,
                                        secondLanguage: "ja")
    }

    @Test func `kinds follow plugin I ds`() {
        #expect(AskKeywordKind(pluginID: AskTranslatePlugin.id) == .translate)
        #expect(AskKeywordKind(pluginID: AskPromptPlugin.id) == .prompt)
        #expect(AskKeywordKind(pluginID: AskWebSearchPlugin.id) == .web)
        #expect(AskKeywordKind(pluginID: AskWorkflowPlugin.idPrefix + "local.x") == .workflow)
        #expect(AskKeywordKind(pluginID: "unknown") == nil)
        #expect(AskKeywordKind.workflow.pluginID == nil)
        for kind in AskKeywordKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.hint.isEmpty && kind.hint != "ask.settings.keywords.kind.\(kind.rawValue).hint")
            #expect(!kind.symbol.isEmpty)
        }
    }

    @Test func `rows list built in keywords by plugin then workflows`() {
        let rows = rows()
        #expect(rows.map(\.keyword) == ["fy", "tr", "翻译", "rw", "sum", "ex", "g", "bd", "gh", "wf", "FY"])
        #expect(rows.map(\.kind) == [.translate, .translate, .translate, .prompt, .prompt, .prompt, .web, .web, .web,
                                     .workflow, .workflow])
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids are unique")
        let workflow = rows[9]
        #expect(workflow.workflowID == "local.python" && workflow.source == nil && workflow.enabled && !workflow
            .shadowed)
        #expect(workflow.summary == L("ask.settings.keywords.summary.workflow"))
        let clash = rows[10]
        #expect(clash.shadowed && !clash.enabled, "a built-in keyword wins over a workflow's")
        #expect(clash.summary == L("ask.settings.keywords.summary.shadowed"))
    }

    @Test func `summaries say what each keyword does`() {
        let rows = rows()
        #expect(rows[0].name == L("ask.plugin.translate.title"))
        #expect(rows[0].summary == L("ask.settings.keywords.summary.auto",
                                     AskTranslationLanguages.name("en", in: .english),
                                     AskTranslationLanguages.name("ja", in: .english)))
        #expect(rows[3].name == AskPromptPlugin.Preset.polish.title)
        #expect(rows[3].summary.hasPrefix("Polish the following text"))
        #expect(!rows[3].summary.contains("\n"), "only the prompt's first line")
        #expect(rows[6].name == "Google" && rows[6].monospacedSummary)
        #expect(rows[6].summary == "www.google.com/search?q={query}")

        let japanese = AskKeyword(keyword: "fyja", pluginID: AskTranslatePlugin.id, options: ["target": "ja"])
        #expect(AskKeywordListPresentation.summary(of: japanese, interface: .english, secondLanguage: "en")
            == L("ask.settings.plugins.translate.into", AskTranslationLanguages.name("ja", in: .english)))
        let blank = AskKeyword(keyword: "p", pluginID: AskPromptPlugin.id, options: ["prompt": "\n  \nFix {input}"])
        #expect(AskKeywordListPresentation
            .summary(of: blank, interface: .english, secondLanguage: "en") == "Fix {input}")
        let empty = AskKeyword(keyword: "p", pluginID: AskPromptPlugin.id)
        #expect(AskKeywordListPresentation.summary(of: empty, interface: .english, secondLanguage: "en")
            == L("ask.settings.plugins.prompt.placeholder"))
        let wiki = AskKeyword(keyword: "w", pluginID: AskWebSearchPlugin.id,
                              options: ["url": "http://wiki.example/?s={query}"])
        #expect(AskKeywordListPresentation.summary(of: wiki, interface: .english, secondLanguage: "en")
            == "wiki.example/?s={query}")
        #expect(AskKeywordListPresentation.name(of: wiki) == "wiki.example")
        let other = AskKeyword(keyword: "x", pluginID: "unknown")
        #expect(AskKeywordListPresentation.summary(of: other, interface: .english, secondLanguage: "en").isEmpty)
        #expect(AskKeywordListPresentation.name(of: other) == "x")
        #expect(AskKeywordListPresentation.withoutScheme("ftp://x") == "ftp://x")
    }

    @Test func `disabled keywords stay listed but off`() {
        var keywords = AskPluginRegistry.defaultKeywords
        keywords[1].enabled = false
        #expect(rows(keywords)[1].enabled == false)
        let off = AskWorkflowKeywordEntry(keyword: "ip", workflowID: "local.ip", workflowName: "IP", enabled: false)
        let row = AskKeywordListPresentation.rows(keywords: [], workflows: [off], interface: .english,
                                                  secondLanguage: "en")[0]
        #expect(!row.enabled && !row.shadowed)
    }

    @Test func `filters by kind and query`() {
        let rows = rows()
        #expect(AskKeywordListPresentation.filter(rows, kind: nil, query: "").count == rows.count)
        #expect(AskKeywordListPresentation.filter(rows, kind: .web, query: "").map(\.keyword) == ["g", "bd", "gh"])
        #expect(AskKeywordListPresentation.filter(rows, kind: nil, query: "  GOOGLE ").map(\.keyword) == ["g"])
        #expect(AskKeywordListPresentation.filter(rows, kind: nil, query: "summarize").map(\.keyword) == ["sum"])
        #expect(AskKeywordListPresentation.filter(rows, kind: .prompt, query: "google").isEmpty)
        let counts = AskKeywordListPresentation.counts(rows)
        #expect(counts[nil] == 11 && counts[.translate] == 3 && counts[.workflow] == 2)
    }

    @MainActor
    @Test func `workflow entries come from manifests`() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.a", manifest: AskWorkflowFixture.inline("local.a", keyword: "aa", script: "echo",
                                                                         extra: ["name": "Alpha"]))
        try fixture.write("local.b", manifest: AskWorkflowFixture.inline("local.b", keyword: "bb", script: "echo"))
        fixture.store.reload()
        fixture.store.trust("local.a")
        fixture.store.trust("local.b")
        fixture.store.setEnabled("local.b", false)
        let entries = AskKeywordListPresentation.workflowEntries(fixture.store.workflows,
                                                                 isEnabled: { fixture.store.isEnabled($0) })
        #expect(entries.map(\.keyword).sorted() == ["aa", "bb"])
        #expect(entries.first { $0.keyword == "aa" }?.workflowName == "Alpha")
        #expect(entries.first { $0.keyword == "aa" }?.enabled == true)
        #expect(entries.first { $0.keyword == "bb" }?.enabled == false)
    }
}

@Suite("Launcher keyword draft")
struct AskKeywordDraftTests {
    private let defaults = AskPluginRegistry.defaultKeywords
    private let workflows = [AskWorkflowKeywordEntry(keyword: "wf", workflowID: "local.p", workflowName: "Python",
                                                     enabled: true)]

    private func keyword(_ word: String) -> AskKeyword {
        defaults.first { $0.keyword == word }!
    }

    @Test func `editing A preset shows its prompt and keeps it out when unchanged`() {
        var draft = AskKeywordDraft(editing: keyword("rw"))
        #expect(!draft.isNew && draft.kind == .prompt && draft.enabled)
        #expect(draft.prompt == AskPromptPlugin.Preset.polish.prompt, "the preset prompt is shown, not hidden")
        #expect(draft.titlePlaceholder == AskPromptPlugin.Preset.polish.title)
        #expect(draft.displayName == AskPromptPlugin.Preset.polish.title)
        #expect(draft.canSave(among: defaults, workflows: workflows))
        var saved = draft.result()
        #expect(saved == keyword("rw"), "nothing changed, nothing new is stored")

        draft.prompt = "Shorten: {input}"
        draft.title = " Short "
        draft.enabled = false
        saved = draft.result()
        #expect(saved.options[AskPromptPlugin.promptOption] == "Shorten: {input}")
        #expect(saved.options[AskPromptPlugin.titleOption] == "Short")
        #expect(saved.options[AskPromptPlugin.presetOption] == "polish", "options the sheet does not show stay")
        #expect(!saved.enabled)
        #expect(draft.displayName == " Short ")

        draft.restorePreset()
        #expect(draft.prompt == AskPromptPlugin.Preset.polish.prompt)
        #expect(draft.result().options[AskPromptPlugin.promptOption] == nil)
    }

    @Test func `a new prompt needs A keyword and A prompt`() {
        var draft = AskKeywordDraft(adding: .prompt)
        #expect(draft.isNew && draft.presetPrompt == nil)
        #expect(draft.titlePlaceholder == L("ask.settings.keywords.sheet.promptNamePlaceholder"))
        #expect(draft.keywordProblem(among: defaults, workflows: workflows) == AskKeywordList.message(for: .empty))
        draft.keyword = "fix"
        #expect(draft.fieldProblem == L("ask.settings.keywords.sheet.promptRequired"))
        #expect(!draft.canSave(among: defaults, workflows: workflows))
        draft.prompt = "Fix: {input}"
        #expect(draft.canSave(among: defaults, workflows: workflows))
        draft.restorePreset()
        #expect(draft.prompt == "Fix: {input}", "no preset to restore")
        let saved = draft.result()
        #expect(saved.pluginID == AskPromptPlugin.id && saved.keyword == "fix")
        #expect(saved.options == [AskPromptPlugin.promptOption: "Fix: {input}"])
    }

    @Test func `keyword problems name who has the word`() {
        var draft = AskKeywordDraft(editing: keyword("tr"))
        #expect(draft.keywordProblem(among: defaults, workflows: workflows) == nil, "its own word is fine")
        draft.keyword = "FY"
        #expect(draft.keywordProblem(among: defaults, workflows: workflows)
            == L("ask.workflow.editor.keywordTakenBy", "fy", L("ask.plugin.translate.title")))
        draft.keyword = "wf"
        #expect(draft.keywordProblem(among: defaults, workflows: workflows)
            == L("ask.workflow.editor.keywordTakenBy", "wf", "Python"))
        draft.keyword = "a b"
        #expect(draft.keywordProblem(among: defaults, workflows: workflows) == AskKeywordList.message(for: .whitespace))
        draft.keyword = "/x"
        #expect(draft.keywordProblem(among: defaults, workflows: workflows) == AskKeywordList.message(for: .slash))
        draft.keyword = " tl "
        #expect(draft.canSave(among: defaults, workflows: workflows))
        #expect(draft.result().keyword == "tl")
    }

    @Test func `translation targets are stored only when chosen`() {
        var draft = AskKeywordDraft(editing: keyword("fy"))
        #expect(draft.kind == .translate && draft.target.isEmpty && draft.fieldProblem == nil)
        #expect(draft.titlePlaceholder.isEmpty)
        #expect(draft.displayName == L("ask.plugin.translate.title"))
        draft.target = "ja"
        #expect(draft.result().options == [AskTranslatePlugin.targetOption: "ja"])
        #expect(draft.displayName.hasPrefix(L("ask.plugin.translate.title") + " · "))
        draft.target = ""
        #expect(draft.result().options.isEmpty)
        let added = AskKeywordDraft(adding: .translate)
        #expect(added.result().pluginID == AskTranslatePlugin.id)
    }

    @Test func `web search keeps built in engines as engines`() {
        var draft = AskKeywordDraft(editing: keyword("bd"))
        #expect(draft.engine == .baidu && draft.url == AskWebSearchPlugin.Engine.baidu.template)
        #expect(draft.titlePlaceholder == AskWebSearchPlugin.Engine.baidu.title)
        #expect(draft.result() == keyword("bd"))

        draft.url = "https://zh.wikipedia.org/w/index.php?search={query}"
        #expect(draft.titlePlaceholder == "zh.wikipedia.org")
        #expect(draft.fieldProblem == nil)
        var saved = draft.result()
        #expect(saved.options[AskWebSearchPlugin.urlOption] == "https://zh.wikipedia.org/w/index.php?search={query}")

        draft.url = "https://example.com/search"
        #expect(draft.fieldProblem == L("ask.settings.plugins.web.problem.query"))
        draft.url = "ftp://example.com/?q={query}"
        #expect(draft.fieldProblem == L("ask.settings.plugins.web.problem.url"))
        #expect(!draft.canSave(among: defaults, workflows: workflows))

        draft.use(.github)
        saved = draft.result()
        #expect(saved.options[AskWebSearchPlugin.engineOption] == "github")
        #expect(saved.options[AskWebSearchPlugin.urlOption] == nil)

        let custom = AskKeyword(
            keyword: "w",
            pluginID: AskWebSearchPlugin.id,
            options: ["url": "https://w.org/?q={query}"]
        )
        let reopened = AskKeywordDraft(editing: custom)
        #expect(reopened.engine == nil && reopened.url == "https://w.org/?q={query}")
        #expect(reopened.titlePlaceholder == "w.org")

        var added = AskKeywordDraft(adding: .web)
        #expect(added.engine == .google && added.url == AskWebSearchPlugin.Engine.google.template)
        added.url = "not a url"
        #expect(added.titlePlaceholder == L("ask.settings.keywords.sheet.webNamePlaceholder"))
    }

    @Test func `saving replaces in place or adds after its plugin`() {
        var list = AskKeywordList(keywords: defaults)
        let polish = keyword("rw")
        var edited = polish
        edited.keyword = "pol"
        list.save(edited, replacing: polish)
        #expect(list.keywords[3].keyword == "pol")
        let fyja = AskKeyword(keyword: "fyja", pluginID: AskTranslatePlugin.id, options: ["target": "ja"])
        list.save(fyja, replacing: nil)
        #expect(list.keywords[3] == fyja, "added after the last translation keyword")
        var empty = AskKeywordList(keywords: [])
        empty.save(fyja, replacing: nil)
        #expect(empty.keywords == [fyja])
        empty.save(polish, replacing: AskKeyword(keyword: "gone", pluginID: "x"))
        #expect(empty.keywords == [fyja, polish])
    }
}

@Suite("Workflow run settings")
struct AskWorkflowRunSettingsTests {
    @Test func `environment rows become the manifest env`() {
        let rows = [
            AskWorkflowRunSettings.EnvRow(name: " LANG ", value: "en_US.UTF-8"),
            AskWorkflowRunSettings.EnvRow(name: "", value: "ignored"),
            AskWorkflowRunSettings.EnvRow(name: "LANG", value: "C"),
            AskWorkflowRunSettings.EnvRow(name: "EMPTY", value: "")
        ]
        #expect(AskWorkflowRunSettings.environment(rows) == ["LANG": "C", "EMPTY": ""])
        #expect(AskWorkflowRunSettings.environment([]).isEmpty)
    }

    @Test func `run settings problems belong to the script step`() {
        #expect(AskWorkflowDraft.step(for: "run.mode") == .output)
        #expect(AskWorkflowDraft.step(for: "run.timeoutSeconds") == .script)
        #expect(AskWorkflowDraft.step(for: "env.TOKEN") == .script)
        #expect(AskWorkflowDraft.step(for: "command.args[0]") == .script)
    }
}
