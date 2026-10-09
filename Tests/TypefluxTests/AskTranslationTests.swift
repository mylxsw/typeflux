import Foundation
import Testing
@testable import Typeflux

@Suite("Ask translation languages")
struct AskTranslationLanguagesTests {
    @Test func codesAndDefaults() {
        #expect(AskTranslationLanguages.code(for: .english) == "en")
        #expect(AskTranslationLanguages.code(for: .simplifiedChinese) == "zh-Hans")
        #expect(AskTranslationLanguages.code(for: .traditionalChinese) == "zh-Hant")
        #expect(AskTranslationLanguages.code(for: .japanese) == "ja")
        #expect(AskTranslationLanguages.code(for: .korean) == "ko")
        #expect(AskTranslationLanguages.defaultSecond(for: .simplifiedChinese) == "en")
        #expect(AskTranslationLanguages.defaultSecond(for: .english) == "zh-Hans")
        #expect(AskTranslationLanguages.name("ja", in: .english) == "Japanese")
        #expect(AskTranslationLanguages.name("en", in: .simplifiedChinese) == "英语")
    }

    @Test func directionFollowsTheInterfaceLanguage() {
        #expect(AskTranslationLanguages.target(source: "en", primary: "zh-Hans", second: "en", preset: nil) == "zh-Hans")
        #expect(AskTranslationLanguages.target(source: "zh-Hans", primary: "zh-Hans", second: "en", preset: nil) == "en")
        #expect(AskTranslationLanguages.target(source: nil, primary: "zh-Hans", second: "en", preset: nil) == "zh-Hans")
        #expect(AskTranslationLanguages.target(source: "en", primary: "zh-Hans", second: "en", preset: "ja") == "ja")
        #expect(AskTranslationLanguages.target(source: "en", primary: "zh-Hans", second: "en", preset: "") == "zh-Hans")
    }

    @Test func languagesCompareByBase() {
        #expect(AskTranslationLanguages.sameLanguage("en-US", "en"))
        #expect(!AskTranslationLanguages.sameLanguage("zh-Hans", "zh-Hant"))
        #expect(AskTranslationLanguages.sameLanguage("zh-TW", "zh-Hant"))
        #expect(AskTranslationLanguages.sameLanguage("zh", "zh-Hans"))
    }

    @Test func tabCyclesTargetsSkippingTheSource() {
        let cycle = AskTranslationLanguages.cycle(primary: "zh-Hans", second: "en")
        #expect(cycle.prefix(3) == ["zh-Hans", "en", "ja"])
        #expect(Set(cycle).count == cycle.count)
        #expect(AskTranslationLanguages.step(from: "zh-Hans", by: 1, primary: "zh-Hans", second: "en", skipping: "en") == "ja")
        #expect(AskTranslationLanguages.step(from: "zh-Hans", by: -1, primary: "zh-Hans", second: "en", skipping: "en")
            == cycle.last)
        #expect(AskTranslationLanguages.step(from: "xx", by: 1, primary: "zh-Hans", second: "en", skipping: nil) == "zh-Hans")
    }

    @Test func theSystemDetectorReadsClearText() {
        let detector = AskLanguageDetector()
        #expect(detector.detect("The quick brown fox jumps over the lazy dog.", hints: ["zh-Hans", "en"]) == "en")
        #expect(detector.detect("明天下午三点开会，记得带上周报。", hints: ["zh-Hans", "en"]) == "zh-Hans")
        #expect(detector.detect("", hints: []) == nil)
    }
}

@Suite("Ask translate plugin", .exclusiveUIState)
struct AskTranslatePluginTests {
    private func plugin(local: Bool = true, ai: AskTestTranslationEngine? = AskTestTranslationEngine(),
                        source: String? = "en") -> (AskTranslatePlugin, AskTestTranslationEngine) {
        let device = AskTestTranslationEngine(available: local)
        return (AskTranslatePlugin(onDevice: device, ai: ai, aiName: { "gpt-test" },
                                   detector: AskTestLanguageDetector(language: source)), device)
    }

    private func request(_ text: String = "Hello world", origin: AskPluginRequest.Origin = .argument,
                         options: [String: String] = [:]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskTranslatePlugin.keywords[0], options: options,
                         interfaceLanguage: .simplifiedChinese)
    }

    @Test func describesItself() {
        let (translate, _) = plugin()
        #expect(translate.id == "translate")
        #expect(!translate.title.isEmpty && translate.symbol == "translate")
        #expect(translate.defaultKeywords.map(\.keyword) == ["fy", "tr", "翻译", "dict", "词典"])
        #expect(translate.placeholder(selectionLines: nil) == L("ask.plugin.translate.placeholder"))
        #expect(translate.placeholder(selectionLines: 0) == L("ask.plugin.translate.placeholder"))
        #expect(translate.placeholder(selectionLines: 2) == L("ask.plugin.translate.placeholder.selection", 2))
        #expect(translate.chipDetail(for: AskTranslatePlugin.keywords[0], language: .english) == nil)
        let japanese = AskKeyword(keyword: "fyja", pluginID: "translate", options: ["target": "ja"])
        #expect(translate.chipDetail(for: japanese, language: .english) == "Japanese")
    }

    @Test func typedTextTranslatesWhileTypingOnThisMac() async {
        let (translate, _) = plugin()
        let plan = await translate.plan(request())
        #expect(plan.mode == .live)
        #expect(plan.values == ["source": "en", "target": "zh-Hans", "engine": "device"])
        #expect(plan.meta.map(\.text) == [AskTranslationLanguages.name("en", in: .simplifiedChinese),
                                           AskTranslationLanguages.name("zh-Hans", in: .simplifiedChinese)])
        #expect(plan.meta.last?.emphasized == true)
        #expect(plan.title == L("ask.plugin.translate.title"))
    }

    @Test func theSelectionAndTheAIWaitForReturn() async {
        let (translate, _) = plugin()
        let selection = await translate.plan(request("one\ntwo", origin: .selection))
        #expect(selection.mode == .onSubmit, "the selection is only translated after Return")
        #expect(selection.title == L("ask.plugin.translate.selection", 2))
        let (remote, _) = plugin(local: false)
        let typed = await remote.plan(request())
        #expect(typed.mode == .onSubmit, "nothing leaves the Mac while typing")
        #expect(typed.values["engine"] == "ai")
        let asked = await translate.plan(request(options: ["engine": "ai"]))
        #expect(asked.mode == .onSubmit && asked.values["engine"] == "ai")
        let unknown = await plugin(source: nil).0.plan(request())
        #expect(unknown.values["source"] == nil && unknown.meta.count == 1)
        let preset = await translate.plan(request(options: ["target": "ja"]))
        #expect(preset.values["target"] == "ja")
    }

    @Test func runsOnTheChosenEngineWithActions() async throws {
        let ai = AskTestTranslationEngine()
        let (translate, device) = plugin(ai: ai)
        let local = try await translate.run(request(), plan: await translate.plan(request()))
        #expect(local.body == "[zh-Hans] Hello world")
        #expect(device.requests.count == 1 && ai.requests.isEmpty)
        #expect(!local.sourceIsAI && local.source == L("ask.plugin.source.device") && local.note == nil)
        #expect(local.action(for: .enter)?.kind == .copy(local.body))
        #expect(local.action(for: .optionEnter)?.kind == .writeBack(local.body))
        #expect(local.action(for: .optionEnter)?.title == L("ask.plugin.action.insert"))
        #expect(local.action(for: .commandR)?.kind == .rerun(["engine": "ai"]))
        #expect(local.action(for: .commandD)?.kind == .compare)
        #expect(local.actions.contains { $0.kind == .speak(local.body, language: "zh-Hans") })
        #expect(local.actions.contains { if case .askAI = $0.kind { true } else { false } })

        let selected = request("Hello", origin: .selection)
        let replaced = try await translate.run(selected, plan: await translate.plan(selected))
        #expect(replaced.action(for: .optionEnter)?.title == L("ask.plugin.action.replace"))

        let (remote, _) = plugin(local: false, ai: ai)
        let fallback = try await remote.run(request(), plan: await remote.plan(request()))
        #expect(fallback.sourceIsAI && fallback.source == L("ask.plugin.source.ai", "gpt-test"))
        #expect(fallback.note == L("ask.plugin.translate.aiFallback"))
        #expect(fallback.action(for: .commandR) == nil, "already the AI")
        let asked = request(options: ["engine": "ai"])
        let chosen = try await translate.run(asked, plan: await translate.plan(asked))
        #expect(chosen.sourceIsAI && chosen.note == nil, "the user asked for the AI")
    }

    @Test func withoutAModelTheAICannotStepIn() async {
        let (translate, _) = plugin(local: false, ai: nil)
        await #expect(throws: AskPluginFailure(message: L("ask.plugin.translate.noModel"), retry: false)) {
            try await translate.run(request(), plan: await translate.plan(request()))
        }
    }

    @Test func tabStepsTheTarget() async {
        let (translate, _) = plugin()
        let plan = await translate.plan(request())
        #expect(translate.nextOptions(after: plan, request: request(), step: 1) == ["target": "ja"])
        let alone = AskPluginPlan(mode: .live, title: "", values: ["target": "zh-Hans", "source": "zh-Hans"])
        #expect(translate.nextOptions(after: alone, request: request(), step: 1) == ["target": "en"])
    }
}

@Suite("Ask translation engines")
struct AskTranslationEngineTests {
    @Test func theAIGetsATranslatorPromptAndReturnsOnlyText() async throws {
        let service = AskTestLLMService()
        service.answer = "  Bonjour le monde \n"
        let engine = AskAITranslationEngine(service: service) { "m" }
        #expect(await engine.canTranslate(from: nil, to: "fr"))
        #expect(try await engine.translate("Hello world", from: "en", to: "fr") == "Bonjour le monde")
        #expect(service.prompts.first?.system.contains("into French") == true)
        #expect(service.prompts.first?.user == "Hello world")
        #expect(engine.modelName() == "m")
        service.answer = "   "
        await #expect(throws: AskPluginFailure.self) { try await engine.translate("Hi", from: nil, to: "fr") }
    }

    @Test func onDeviceNeedsAKnownSource() async {
        let engine = AskOnDeviceTranslationEngine()
        #expect(await engine.canTranslate(from: nil, to: "en") == false)
        await #expect(throws: AskPluginFailure.self) { try await engine.translate("Hi", from: nil, to: "en") }
    }
}
