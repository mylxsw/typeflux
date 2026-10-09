import Foundation
import Testing
@testable import Typeflux

@Suite("Launcher localization polish", .serialized, .exclusiveUIState)
@MainActor
struct AskLocalizationPolishTests {
    @Test func cloudSignInFailureFallsBackOnlyToAConfiguredService() async throws {
        let device = AskTestTranslationEngine(available: false)
        let cloudEngine = AskTestTranslationEngine(failure: TypefluxCloudLLMError.notLoggedIn)
        let service = AskTestTranslationEngine()
        let request = AskPluginRequest(text: "Hello world", origin: .argument, keyword: AskTranslatePlugin.keywords[0],
                                       options: [:], interfaceLanguage: .simplifiedChinese)
        var plugin = AskTranslatePlugin(onDevice: device, ai: cloudEngine, service: { _ in service }, signedOutFallback: { .deepl },
                                         detector: AskTestLanguageDetector(language: "en"))
        let plan = await plugin.plan(request)
        let output = try await plugin.run(request, plan: plan)
        #expect(output.body == "[zh-Hans] Hello world" && output.source == "DeepL" && !output.sourceIsAI)
        #expect(output.note == L("ask.plugin.translate.signInFallback", "DeepL"))
        #expect(service.requests.count == 1 && cloudEngine.requests.count == 1)
        service.failure = AskTranslationServiceError.authentication
        do {
            _ = try await plugin.run(request, plan: plan)
            Issue.record("Failed fallback must surface its service error")
        } catch let error as AskPluginFailure { #expect(!error.retry) }
        #expect(cloudEngine.requests.count == 2, "The fallback must not recurse back into Cloud")
        plugin.signedOutFallback = { nil }
        do {
            _ = try await plugin.run(request, plan: plan)
            Issue.record("No configured fallback requires sign-in")
        } catch TypefluxCloudLLMError.notLoggedIn {}
        cloudEngine.failure = URLError(.timedOut)
        plugin.signedOutFallback = { .deepl }
        do {
            _ = try await plugin.run(request, plan: plan)
            Issue.record("Network errors must not silently switch engines")
        } catch is URLError {}
        #expect(service.requests.count == 2)
    }

    @Test func fallbackProviderRequiresCompleteCredentialsAndPrefersTheChosenEngine() {
        let credentials = AskTestTranslationCredentials([.deepl: .init(key: "fixture"), .youdao: .init(key: "incomplete")])
        #expect(AskTranslationProvider.configuredFallback(credentials: credentials) == .deepl)
        #expect(AskTranslationProvider.configuredFallback(credentials: credentials, preferred: .youdao) == .deepl)
        _ = credentials.save(.init(key: "fixture", secret: "fixture"), for: .youdao)
        #expect(AskTranslationProvider.configuredFallback(credentials: credentials, preferred: .youdao) == .youdao)
        #expect(AskTranslationProvider.configuredFallback(credentials: AskTestTranslationCredentials()) == nil)
    }

    @Test func cloudErrorsUseLocalizedCopyAndOfferSignIn() throws {
        let errors: [(Error, String)] = [
            (TypefluxCloudLLMError.notLoggedIn, "cloud.error.llmSignInRequired"),
            (TypefluxOfficialASRError.notLoggedIn, "cloud.error.asrSignInRequired"),
            (TypefluxOfficialASRRoutingError.unauthorized, "cloud.error.asrSignInRequired")
        ]
        for (error, key) in errors {
            #expect(error.localizedDescription == L(key))
            let failure = AskPluginFailure.presenting(error)
            #expect(!failure.retry && failure.message == L(key))
            let action = try #require(failure.action(for: .enter))
            #expect(action.kind == .signIn && action.title == L("ask.submission.signIn"))
            let display = AskPluginDisplay(title: "Translation", symbol: "translate",
                                           phase: .failed(.init(mode: .onSubmit, title: ""), failure))
            #expect(AskPluginResultsView.hint(for: display) == L("ask.plugin.hint.action", action.title))
        }
        let existing = AskPluginFailure(message: "Custom", retry: false)
        #expect(AskPluginFailure.presenting(existing) == existing)
        #expect(AskPluginFailure.presenting(URLError(.timedOut)).retry)
    }

    @Test func signingInKeepsTheLauncherDraft() throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft = AskDraft(text: "Translate this", includeScreenshot: false, selection: "Selected text")
        let draft = fixture.model.launcherDraft
        var signIns = 0
        fixture.model.onSignIn = { signIns += 1 }
        #expect(fixture.model.performPluginAction(.init(kind: .signIn, title: "", symbol: "")) == .stay)
        #expect(signIns == 1 && fixture.model.launcherDraft == draft)
    }

    @Test func presetsDescribeTheTaskAndCustomPromptsStayBrief() {
        for preset in AskPromptPlugin.Preset.allCases {
            let keyword = AskKeyword(keyword: preset.keyword, pluginID: AskPromptPlugin.id,
                                     options: [AskPromptPlugin.presetOption: preset.rawValue])
            #expect(AskKeywordListPresentation.summary(of: keyword, interface: .english, secondLanguage: "ja")
                == L("ask.plugin.prompt.description." + preset.rawValue))
        }
        func summary(_ prompt: String) -> String {
            AskKeywordListPresentation.summary(of: .init(keyword: "custom", pluginID: AskPromptPlugin.id,
                options: ["preset": "polish", "prompt": prompt]), interface: .english, secondLanguage: "ja")
        }
        #expect(summary("  First sentence. Another sentence.\n{input}") == "First sentence.")
        #expect(summary("Explain this！More text") == "Explain this！")
        #expect(summary(String(repeating: "x", count: 150)).count == 121)
        #expect(summary("{input}") == L("ask.settings.plugins.prompt.placeholder"))
    }

    @Test func modelAvailabilityTakesACloudCapability() throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        let issue = fixture.model.modelSelectionIssue("cloud:default", cloudAvailable: false, hasImage: false)
        #expect(issue?.offersModels == true && issue?.offersSignIn == true)
        #expect(issue?.text == L("ask.local.modelRequired"))
        #expect(fixture.model.modelSelectionIssue("cloud:default", cloudAvailable: true, hasImage: false) == nil)
        #expect(fixture.model.modelSelectionIssue("custom:missing", cloudAvailable: false, hasImage: false)?.offersModels == true)
        #expect(!AskLocalModeStatus.make(model: fixture.model, signedIn: false).modelAvailable)
    }

    @Test func voiceButtonNamesTrackRecordingAndContext() {
        #expect(AskVoiceButton.title(phase: .idle, contextMatches: true) == L("ask.voice.input"))
        #expect(AskVoiceButton.title(phase: .listening, contextMatches: true) == L("ask.voice.stop"))
        #expect(AskVoiceButton.title(phase: .transcribing, contextMatches: true) == L("ask.voice.transcribing"))
        #expect(AskVoiceButton.title(phase: .listening, contextMatches: false) == L("ask.voice.input"))
    }

    @Test func invalidRowsCannotSupplyActionsOrKeepSelection() {
        let action = AskPluginAction(kind: .copy("text"), title: "Copy", symbol: "doc", shortcut: .enter)
        let invalid = AskPluginItem(id: "notice", title: "No results", valid: false, actions: [action])
        let valid = AskPluginItem(id: "result", title: "Result", actions: [action])
        let output = AskPluginOutput(body: "", original: "", meta: [], source: "", actions: [], items: [invalid, valid])
        #expect(output.selected == nil && output.action(for: .enter) == nil)
        #expect(output.selectableIndices == [1])
        #expect(AskPluginSession.selection(keeping: output, in: output) == 1)
        let empty = AskPluginOutput(body: "", original: "", meta: [], source: "", actions: [], items: [invalid])
        #expect(AskPluginSession.selection(keeping: output, in: empty) == -1)
    }

    @Test func aPluginCanChooseAnInitiallyValidRow() async throws {
        let plugin = ListPlugin(selectedItem: 3)
        let session = AskPluginSession(plugins: [plugin], keywords: { plugin.defaultKeywords })
        defer { session.deactivate() }
        session.enter(plugin.defaultKeywords[0])
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        try await fixture.wait { session.output != nil }
        #expect(session.output?.selectedItem == 3)
    }

    @Test func navigationSkipsInvalidRowsAndAnEmptyHistoryHasNoActionHint() async throws {
        let plugin = ListPlugin()
        let session = AskPluginSession(plugins: [plugin], keywords: { plugin.defaultKeywords })
        defer { session.deactivate() }
        session.enter(plugin.defaultKeywords[0])
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        try await fixture.wait { session.output != nil }
        #expect(session.output?.selectedItem == 1)
        #expect(session.moveSelection(1) && session.output?.selectedItem == 3)
        #expect(!session.moveSelection(1) && !session.moveSelection(0))
        #expect(!session.selectItem(2) && session.output?.selectedItem == 3)
        #expect(session.moveSelection(-1) && session.output?.selectedItem == 1)
        let history = AskHistoryPlugin(conversations: { .empty })
        let request = AskPluginRequest(text: "", origin: .argument, keyword: AskHistoryPlugin.keywords[0],
                                       options: [:], interfaceLanguage: .english)
        let plan = await history.plan(request)
        let output = try await history.run(request, plan: plan)
        #expect(output.items[0].title == L("ask.history.empty"))
        #expect(!output.items[0].valid)
        let display = AskPluginDisplay(title: history.title, symbol: history.symbol, phase: .done(plan, output), offersAskAI: false)
        #expect(AskPluginResultsView.hint(for: display).isEmpty)
        let noActions = AskPluginOutput(body: "No results", original: "", meta: [], source: "", actions: [])
        let card = AskPluginDisplay(title: "Empty", symbol: "clock", phase: .done(plan, noActions))
        #expect(AskPluginResultsView.hint(for: card) == L("ask.plugin.hint.askAI"))
    }

    private struct ListPlugin: AskLauncherPlugin {
        var selectedItem = 0
        let id = "list-polish"
        let title = "List"
        let symbol = "list.bullet"
        var defaultKeywords: [AskKeyword] { [.init(keyword: "list", pluginID: id)] }
        func placeholder(selectionLines: Int?) -> String { "" }
        func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
        func plan(_ request: AskPluginRequest) async -> AskPluginPlan { .init(mode: .onSubmit, title: title) }
        func run(_ request: AskPluginRequest, plan: AskPluginPlan,
                 progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
            let items: [AskPluginItem] = (0 ..< 5).map { index in
                AskPluginItem(id: String(index), title: String(index), valid: index % 2 == 1)
            }
            var output = AskPluginOutput(body: "", original: "", meta: [], source: "", actions: [], items: items)
            output.selectedItem = selectedItem
            return output
        }
        func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
    }
}
