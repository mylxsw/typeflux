import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Settings read by a plugin under test, changed between runs.
final class AskTestTranslationSettingsBox: @unchecked Sendable {
    var value: AskTranslationSettings
    init(_ value: AskTranslationSettings = AskTranslationSettings()) { self.value = value }
}

@Suite("Ask translate plugin engines")
struct AskTranslationRoutingTests {
    private struct Setup {
        let plugin: AskTranslatePlugin
        let device: AskTestTranslationEngine
        let ai: AskTestTranslationEngine
        let services: [AskTranslationProvider: AskTestTranslationEngine]
        let settings: AskTestTranslationSettingsBox
    }

    private func setup(local: Bool = true, settings: AskTranslationSettings = AskTranslationSettings(),
                       ai: Bool = true, services: Bool = true, failing: Error? = nil,
                       dictionary: (any AskWordLookingUp)? = nil) -> Setup {
        let device = AskTestTranslationEngine(available: local)
        let aiEngine = AskTestTranslationEngine()
        let engines = Dictionary(uniqueKeysWithValues: AskTranslationProvider.allCases.map {
            ($0, AskTestTranslationEngine(failure: failing))
        })
        let box = AskTestTranslationSettingsBox(settings)
        let lookUp: @Sendable (AskTranslationProvider) -> any AskTranslationEngine = { engines[$0]! }
        let aiOrNil: (any AskTranslationEngine)? = ai ? aiEngine : nil
        var plugin = AskTranslatePlugin(onDevice: device, ai: aiOrNil, dictionary: dictionary)
        plugin.aiName = { "gpt-test" }
        plugin.engineSettings = { box.value }
        plugin.service = services ? lookUp : nil
        plugin.detector = AskTestLanguageDetector(language: "en")
        return Setup(plugin: plugin, device: device, ai: aiEngine, services: engines, settings: box)
    }

    private func request(_ text: String = "Hello world", options: [String: String] = [:]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: options,
                         interfaceLanguage: .simplifiedChinese)
    }

    private func run(_ setup: Setup, _ request: AskPluginRequest) async throws -> AskPluginOutput {
        try await setup.plugin.run(request, plan: await setup.plugin.plan(request))
    }

    @Test func thisMacStillComesFirst() async throws {
        let deepl = setup(settings: AskTranslationSettings(engine: .service(.deepl)))
        let plan = await deepl.plugin.plan(request())
        #expect(plan.values["engine"] == "device" && plan.mode == .live)
        let output = try await run(deepl, request())
        #expect(output.source == L("ask.plugin.source.device"))
        #expect(deepl.services[.deepl]!.requests.isEmpty)
    }

    @Test func theChosenServiceTranslatesAfterReturn() async throws {
        let deepl = setup(local: false, settings: AskTranslationSettings(engine: .service(.deepl)))
        let plan = await deepl.plugin.plan(request())
        #expect(plan.values["engine"] == "deepl")
        #expect(plan.mode == .onSubmit, "nothing goes to a service while typing")
        #expect(plan.title == L("ask.plugin.translate.title"))
        let output = try await run(deepl, request())
        #expect(output.body == "[zh-Hans] Hello world")
        #expect(output.source == "DeepL" && !output.sourceIsAI && output.note == nil)
        #expect(deepl.services[.deepl]!.requests.count == 1 && deepl.ai.requests.isEmpty)
        #expect(output.action(for: .commandR)?.kind == .rerun(["engine": "ai"]), "⌘R still asks the AI")
    }

    @Test func turningOffOnDeviceSkipsThisMac() async throws {
        let remote = setup(settings: AskTranslationSettings(engine: .service(.youdao), prefersOnDevice: false))
        #expect(await remote.plugin.plan(request()).values["engine"] == "youdao")
        let ai = setup(settings: AskTranslationSettings(prefersOnDevice: false))
        #expect(await ai.plugin.plan(request()).values["engine"] == "ai")
        let output = try await run(ai, request())
        #expect(output.sourceIsAI && output.note == nil, "the AI was chosen, not a fallback")
        #expect(ai.device.requests.isEmpty)
    }

    @Test func aKeywordCanNameAService() async throws {
        let keyword = setup()
        let asked = request(options: ["engine": "baidu"])
        let plan = await keyword.plugin.plan(asked)
        #expect(plan.values["engine"] == "baidu", "even where this Mac could translate")
        let output = try await run(keyword, asked)
        #expect(output.source == AskTranslationProvider.baidu.title)
        #expect(keyword.services[.baidu]!.requests.count == 1)
        // Without services the keyword's choice falls back to the usual engines.
        let none = setup(services: false)
        #expect(await none.plugin.plan(asked).values["engine"] == "device")
        let detail = keyword.plugin.chipDetail(
            for: AskKeyword(keyword: "dl", pluginID: "translate", options: ["engine": "deepl", "target": "ja"]),
            language: .english
        )
        #expect(detail == "Japanese · DeepL")
        #expect(keyword.plugin.chipDetail(for: AskKeyword(keyword: "dl", pluginID: "translate",
                                                          options: ["engine": "deepl"]), language: .english) == "DeepL")
    }

    @Test func aFailingServiceHandsOverToTheAI() async throws {
        let failing = setup(local: false, settings: AskTranslationSettings(engine: .service(.google)),
                            failing: AskTranslationServiceError.quota)
        let output = try await run(failing, request())
        #expect(output.sourceIsAI && output.source == L("ask.plugin.source.ai", "gpt-test"))
        #expect(output.note == L("ask.plugin.translate.serviceFallback", "Google",
                                 AskTranslationServiceError.quota.localizedDescription))
        #expect(failing.ai.requests.count == 1)
        #expect(output.action(for: .commandR) == nil, "already the AI")
    }

    @Test func withoutFallbackTheServiceErrorShows() async {
        let strict = setup(local: false, settings: AskTranslationSettings(engine: .service(.google), fallsBackToAI: false),
                           failing: AskTranslationServiceError.authentication)
        await #expect(throws: AskPluginFailure(
            message: L("ask.translation.error.from", "Google", AskTranslationServiceError.authentication.localizedDescription),
            retry: false
        )) { try await run(strict, request()) }
        let noAI = setup(local: false, settings: AskTranslationSettings(engine: .service(.google)), ai: false,
                         failing: URLError(.timedOut))
        do {
            _ = try await run(noAI, request())
            Issue.record("expected a failure")
        } catch let failure as AskPluginFailure {
            #expect(failure.retry, "a network error may pass")
            #expect(failure.message.hasPrefix("Google"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func cancellingDoesNotFallBack() async {
        let cancelled = setup(local: false, settings: AskTranslationSettings(engine: .service(.google)),
                              failing: CancellationError())
        await #expect(throws: CancellationError.self) { try await run(cancelled, request()) }
        #expect(cancelled.ai.requests.isEmpty)
    }

    @Test func wordsTranslatedByAServiceOfferACard() async throws {
        let lookup = AskTestWordLookup(answer: .translation("x"))
        let words = setup(local: false, settings: AskTranslationSettings(engine: .service(.deepl)), dictionary: lookup)
        let plan = await words.plugin.plan(request("apple"))
        #expect(plan.values["engine"] == "deepl" && plan.title == L("ask.plugin.translate.title"))
        let output = try await run(words, request("apple"))
        #expect(output.note == L("ask.plugin.translate.cardHint", "gpt-test"))
        #expect(output.action(for: .commandR)?.title == L("ask.plugin.action.wordCard"))
        #expect(lookup.requests.isEmpty)
    }

    @Test func serviceFailuresSayWhetherRetryingHelps() {
        #expect(!AskTranslatePlugin.failure(AskTranslationServiceError.quota, provider: .deepl).retry)
        #expect(AskTranslatePlugin.failure(AskTranslationServiceError.rateLimited, provider: .deepl).retry)
        let plain = AskPluginFailure(message: "boom")
        #expect(AskTranslatePlugin.reason(plain) == "boom")
        #expect(AskTranslatePlugin.failure(plain, provider: .deepl).message == L("ask.translation.error.from", "DeepL", "boom"))
    }
}

@Suite("Ask translation model")
struct AskTranslationLLMServiceTests {
    @Test func followsTheTextModelUntilOneIsChosen() async throws {
        let text = AskTestLLMService()
        text.answer = "text"
        let chosen = AskTestLLMService()
        chosen.answer = "chosen"
        var reference = ""
        var exists = true
        let service = AskTranslationLLMService(reference: { reference }, exists: { _ in exists },
                                               textProcessing: text, chosen: chosen)
        #expect(try await service.complete(systemPrompt: "s", userPrompt: "u") == "text")
        reference = "custom:fast"
        #expect(try await service.complete(systemPrompt: "s", userPrompt: "u") == "chosen")
        chosen.jsonAnswer = #"{"kind":"word"}"#
        #expect(try await service.completeJSON(systemPrompt: "s", userPrompt: "u",
                                               schema: LLMJSONSchema(name: "n", schema: [:])) == #"{"kind":"word"}"#)
        var streamed = ""
        for try await piece in service.streamComplete(systemPrompt: "s", userPrompt: "u") { streamed += piece }
        #expect(streamed == "chosen")
        exists = false
        await #expect(throws: AskPluginFailure(message: L("ask.translation.error.modelMissing"), retry: false)) {
            try await service.complete(systemPrompt: "s", userPrompt: "u")
        }
        await #expect(throws: AskPluginFailure.self) {
            for try await _ in service.streamComplete(systemPrompt: "s", userPrompt: "u") {}
        }
    }

    @Test func theSettingsServiceReadsTheChosenModel() async {
        let defaults = UserDefaults(suiteName: "AskTranslationLLMServiceTests-" + UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        let text = AskTestLLMService()
        let service = AskTranslationLLMService(settings: settings, textProcessing: text)
        _ = try? await service.complete(systemPrompt: "s", userPrompt: "u")
        #expect(text.prompts.count == 1, "no model chosen: the text-processing model")
        settings.askTranslationSettings = AskTranslationSettings(modelReference: "custom:gone")
        await #expect(throws: AskPluginFailure.self) { try await service.complete(systemPrompt: "s", userPrompt: "u") }
        #expect(text.prompts.count == 1)
    }
}

@Suite("Ask translation settings pane")
@MainActor
struct AskTranslationSettingsModelTests {
    private func model(_ credentials: AskTestTranslationCredentials = AskTestTranslationCredentials())
        -> AskTranslationSettingsModel {
        let defaults = UserDefaults(suiteName: "AskTranslationSettingsModelTests-" + UUID().uuidString)!
        return AskTranslationSettingsModel(store: SettingsStore(defaults: defaults), credentials: credentials)
    }

    @Test func choicesAreSaved() {
        let model = model(AskTestTranslationCredentials([.deepl: .init(key: "k")]))
        #expect(model.configured == [.deepl])
        #expect(model.engineOptions.first?.value == "ai")
        #expect(model.engineOptions.count == AskTranslationProvider.allCases.count + 1)
        #expect(model.engineOptions.contains { $0.value == "deepl" && $0.label == "DeepL" })
        #expect(model.engineOptions.contains {
            $0.value == "google" && $0.label == L("ask.translation.engine.notConfigured", "Google")
        })
        model.setEngine("deepl")
        model.setModel("custom:fast")
        model.setPrefersOnDevice(false)
        model.setFallsBackToAI(false)
        model.setSecondLanguage("ja")
        #expect(model.store.askTranslationSettings == AskTranslationSettings(
            engine: .service(.deepl), modelReference: "custom:fast", prefersOnDevice: false, fallsBackToAI: false
        ))
        #expect(model.store.askTranslationSecondLanguage == "ja" && model.secondLanguage == "ja")
        model.setEngine("deepl")
        #expect(model.settings.engine == .service(.deepl))
    }

    @Test func modelOptionsFollowTheTextModelFirst() {
        let providers = [RegisteredProvider(id: "p", name: "Mine",
                                            models: [RegisteredModel(id: "m", name: "Fast", reference: "custom:fast")])]
        let options = AskTranslationSettingsModel.modelOptions(providers: providers, selected: "")
        #expect(options.map(\.value) == ["", "custom:fast"])
        #expect(options[0].label == L("ask.translation.model.follow") && options[1].label == "Mine · Fast")
        let gone = AskTranslationSettingsModel.modelOptions(providers: providers, selected: "custom:gone")
        #expect(gone.last?.value == "custom:gone" && gone.last?.label == L("ask.models.unavailable"))
    }

    @Test func editingSavesAndRemovesKeys() {
        let credentials = AskTestTranslationCredentials()
        let model = model(credentials)
        #expect(!model.canSave && !model.save())
        model.edit(.youdao)
        #expect(model.editing == .youdao && model.draft == AskTranslationCredentials())
        model.draft.key = " app "
        #expect(!model.canSave, "Youdao needs its secret too")
        model.draft.secret = "sec"
        #expect(model.canSave && model.save())
        #expect(credentials.credentials(for: .youdao) == AskTranslationCredentials(key: "app", secret: "sec"))
        #expect(model.configured.contains(.youdao) && model.editing == nil)
        model.setEngine("youdao")
        model.edit(.youdao)
        #expect(model.draft.key == "app")
        model.remove()
        #expect(credentials.credentials(for: .youdao) == nil && !model.configured.contains(.youdao))
        #expect(model.settings.engine == .ai, "a removed service no longer translates")
        model.remove()
        model.edit(.deepl)
        model.draft.key = "k"
        credentials.refusesSaving = true
        #expect(!model.save())
        #expect(model.noticeIsError && model.notice == L("ask.translation.keychainFailed"))
        model.cancelEdit()
        #expect(model.editing == nil && model.notice == nil)
    }

    @Test func testingReportsTheResult() async {
        let model = model()
        model.test()
        #expect(!model.testing, "nothing to test without keys")
        model.edit(.deepl)
        model.draft.key = "k:fx"
        model.http = AskTestTranslationHTTP([(#"{"translations":[{"text":"你好"}]}"#, 200)])
        model.test()
        #expect(model.testing)
        await model.waitForTest()
        #expect(!model.testing && !model.noticeIsError)
        #expect(model.notice == L("ask.translation.test.success", "你好"))
        model.http = AskTestTranslationHTTP([("{}", 403)])
        model.test()
        await model.waitForTest()
        #expect(model.noticeIsError && model.notice == AskTranslationServiceError.authentication.localizedDescription)
    }
}

@Suite("Ask translation provider sheet")
@MainActor
struct AskTranslationProviderSheetTests {
    @Test func everyProviderSheetDraws() async throws {
        let defaults = UserDefaults(suiteName: "AskTranslationProviderSheetTests-" + UUID().uuidString)!
        let credentials = AskTestTranslationCredentials([.deepl: .init(key: "k")])
        let model = AskTranslationSettingsModel(store: SettingsStore(defaults: defaults), credentials: credentials)
        _ = NSApplication.shared
        for provider in AskTranslationProvider.allCases {
            model.edit(provider)
            if provider == .deepl {
                model.http = AskTestTranslationHTTP([("{}", 403)])
                model.test()
                await model.waitForTest()
                #expect(model.notice != nil)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AskTranslationProviderSheet(model: model, provider: provider))
            window.contentView = hosting
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height > 100, "\(provider)")
            window.orderOut(nil)
            window.close()
        }
        model.cancelEdit()
    }
}

@Suite("Ask keyword draft translation service")
struct AskKeywordDraftServiceTests {
    @Test func keywordsCanNameAService() {
        var draft = AskKeywordDraft(adding: .translate)
        draft.keyword = "dl"
        draft.translationService = "deepl"
        draft.target = "ja"
        let keyword = draft.result()
        #expect(keyword.options == ["engine": "deepl", "target": "ja"])
        #expect(draft.displayName.hasSuffix(" · DeepL"))
        let editing = AskKeywordDraft(editing: keyword)
        #expect(editing.translationService == "deepl")
        var plain = editing
        plain.translationService = ""
        #expect(plain.result().options == ["target": "ja"])
        var book = editing
        book.opensWordBook = true
        #expect(book.result().options[AskTranslatePlugin.engineOption] == nil)
        let unknown = AskKeywordDraft(editing: AskKeyword(keyword: "x", pluginID: "translate", options: ["engine": "ai"]))
        #expect(unknown.translationService.isEmpty)
    }
}
