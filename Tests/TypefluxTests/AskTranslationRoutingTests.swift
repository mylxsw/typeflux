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

@Suite("Ask translate plugin services", .exclusiveUIState)
@MainActor
struct AskTranslationRoutingTests {
    private func request(_ text: String = "The meeting is on Thursday.", options: [String: String] = [:]) -> AskPluginRequest {
        .init(text: text, origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: options,
              interfaceLanguage: .simplifiedChinese)
    }

    @Test func typingUsesOnlyDeviceAndReturnFansOut() async throws {
        let device = AskTestTranslationEngine()
        let ai = AskTestTranslationEngine()
        let provider = AskTestTranslationEngine()
        let settings = AskTranslationSettings(services: [.device, .provider(.deepl, enabled: true), .ai()])
        let plugin = AskTranslatePlugin(onDevice: device, ai: ai, serviceSettings: { settings }, service: { _ in provider },
                                        fanout: AskTranslationFanout(), detector: AskTestLanguageDetector(language: "en"))
        let input = request()
        var plan = await plugin.plan(input)
        #expect(plan.mode == .live)
        let preview = try await plugin.run(input, plan: plan)
        #expect(preview.translation?.results.map(\.id) == ["device"])
        #expect(ai.requests.isEmpty && provider.requests.isEmpty)
        plan.values["submitted"] = "true"
        let output = try await plugin.run(input, plan: plan)
        #expect(output.translation?.results.map(\.id) == ["device", "provider.deepl", "ai.primary"])
        #expect(ai.requests.count == 1 && provider.requests.count == 1)
        #expect(output.action(for: .enter)?.kind == .copy("[zh-Hans] " + input.text))
    }

    @Test func keywordOverridesUseExactlyOneService() async throws {
        let device = AskTestTranslationEngine()
        let ai = AskTestTranslationEngine()
        let provider = AskTestTranslationEngine()
        let plugin = AskTranslatePlugin(onDevice: device, ai: ai, service: { _ in provider },
                                        detector: AskTestLanguageDetector(language: "en"))
        for engine in ["deepl", "ai", "device"] {
            let input = request(options: ["engine": engine])
            let plan = await plugin.plan(input)
            #expect(plan.mode == (engine == "device" ? .live : .onSubmit))
            let output = try await plugin.run(input, plan: plan)
            #expect(output.translation?.results.count == 1)
            #expect(output.translation?.results.first?.service.id == (engine == "deepl" ? "provider.deepl" : engine == "ai" ? "ai.primary" : "device"))
        }
        #expect(device.requests.count == 1 && ai.requests.count == 1 && provider.requests.count == 1)
        let keyword = AskKeyword(keyword: "dl", pluginID: "translate", options: ["engine": "deepl", "target": "ja"])
        #expect(plugin.chipDetail(for: keyword, language: .english) == "Japanese · DeepL")
        #expect(plugin.selectedServices(request(options: ["engine": "unknown"])) == AskTranslationSettings().services)
    }

    @Test func unavailableDeviceAndServiceFailureStayInTheirOwnRows() async throws {
        let device = AskTestTranslationEngine(available: false)
        let ai = AskTestTranslationEngine()
        let provider = AskTestTranslationEngine(failure: AskTranslationServiceError.authentication)
        let settings = AskTranslationSettings(services: [.device, .provider(.deepl, enabled: true), .ai()])
        let plugin = AskTranslatePlugin(onDevice: device, ai: ai, serviceSettings: { settings }, service: { _ in provider },
                                        detector: AskTestLanguageDetector(language: "en"))
        let output = try await plugin.run(request(), plan: await plugin.plan(request()))
        let rows = try #require(output.translation?.results)
        #expect(rows.count == 3)
        if case .failed = rows[0].state {} else { Issue.record("Device failure missing") }
        if case let .failed(failure) = rows[1].state { #expect(failure.recovery == .configure) } else { Issue.record("Provider failure missing") }
        #expect(rows[2].completedText != nil && ai.requests.count == 1)
        #expect(output.action(for: .enter) == nil, "a failed first item cannot copy another service implicitly")
    }

    @Test func checkedAIOwnsTheKeywordOverrideAndRegenerationTarget() async throws {
        let settings = AskTranslationSettings(services: [.device, .ai(enabled: false), .ai(id: "second")])
        let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: AskTestTranslationEngine(),
                                        serviceSettings: { settings }, detector: AskTestLanguageDetector(language: "en"))
        #expect(plugin.selectedServices(request(options: ["engine": "ai"])).map(\.id) == ["second"])
        let input = request("apple")
        let preview = try await plugin.run(input, plan: await plugin.plan(input))
        if case let .rerun(options) = preview.action(for: .commandR)?.kind {
            #expect(options["regenerateService"] == "second")
        } else { Issue.record("Missing regeneration target") }
        let noAI = AskTranslationSettings(services: [.ai(enabled: false), .ai(id: "second", enabled: false)])
        let fallback = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: nil, serviceSettings: { noAI })
        #expect(fallback.selectedServices(request(options: ["engine": "ai"])).first?.id == "ai.primary")
    }

    @Test(arguments: [false, true])
    func cachedCardsUseTheCheckedAIOrGiveWayToBriefTranslations(checked: Bool) async throws {
        let book = makeTestWordBook()
        let card = AskWordCard(headword: "apple", translation: "苹果")
        book.record(.init(headword: "apple", source: "en", target: "zh-Hans", card: card), at: Date(), counts: false)
        let ai = AskTestTranslationEngine()
        let provider = AskTestTranslationEngine()
        let settings = AskTranslationSettings(services: [
            .device, .ai(enabled: false), .ai(id: "second", enabled: checked), .provider(.deepl, enabled: true)
        ])
        let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: ai, wordBook: book,
                                        serviceSettings: { settings }, service: { _ in provider },
                                        detector: AskTestLanguageDetector(language: "en"))
        let input = request("apple")
        var plan = await plugin.plan(input)
        plan.values["submitted"] = "true"
        let output = try await plugin.run(input, plan: plan)
        #expect(ai.requests.isEmpty && provider.requests.count == 1)
        if checked {
            #expect(output.translation?.results.first?.id == "second" && output.wordCard == card)
        } else {
            #expect(output.translation?.results.map(\.id) == ["device", "provider.deepl"])
            #expect(output.wordCard == nil && output.translation?.results.allSatisfy { $0.card == nil } == true)
        }
    }

    @Test func pendingReturnAuthorizesOnlyTheTextItWasPressedFor() async throws {
        let device = AskTestTranslationEngine()
        let ai = AskTestTranslationEngine()
        let plugin = AskTranslatePlugin(onDevice: device, ai: ai, detector: AskTestLanguageDetector(language: "en"))
        let session = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: "Old sentence.", selection: nil, language: .english)
        #expect(session.run(), "Return is queued while planning")
        session.update(text: "New sentence.", selection: nil, language: .english)
        for _ in 0..<200 where session.output?.original != "New sentence." { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ai.requests.isEmpty && session.output?.translation?.submitted == false)
        session.update(text: "Submitted sentence.", selection: nil, language: .english)
        #expect(session.run())
        for _ in 0..<200 where session.output?.translation?.submitted != true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ai.requests.map(\.text) == ["Submitted sentence."])
        session.deactivate()
    }

    @Test func manualTargetSurvivesInputChangesAndSourceCanBeReset() async throws {
        let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: nil,
                                        detector: AskTestLanguageDetector(language: "en"))
        #expect(await plugin.plan(request(options: ["target": "ja"])).values["target"] == "ja")
        #expect(await plugin.plan(request("Changed text.", options: ["target": "ja", "source": "fr"])).values["source"] == "fr")
        #expect(await plugin.plan(request(options: ["source": ""])).values["source"] == "en")
        let empty = request("")
        #expect(try await plugin.run(empty, plan: await plugin.plan(empty)).items.count == 1)
        #expect(!AskTranslatePlugin.failure(AskTranslationServiceError.quota, provider: .deepl).retry)
        #expect(AskTranslatePlugin.failure(URLError(.timedOut), provider: .deepl).retry)
        #expect(AskTranslatePlugin.reason(AskPluginFailure(message: "boom")) == "boom")
    }
}

@Suite("Ask translation model", .exclusiveUIState)
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

@Suite("Ask translation settings pane", .exclusiveUIState)
@MainActor
struct AskTranslationSettingsModelTests {
    private func model(_ credentials: AskTestTranslationCredentials = AskTestTranslationCredentials())
        -> AskTranslationSettingsModel {
        let defaults = UserDefaults(suiteName: "AskTranslationSettingsModelTests-" + UUID().uuidString)!
        return AskTranslationSettingsModel(store: SettingsStore(defaults: defaults), credentials: credentials)
    }

    @Test func orderedServicesPersistAndUnconfiguredEnablingOpensTheSheet() {
        let model = model(AskTestTranslationCredentials([.deepl: .init(key: "k")]))
        #expect(model.configured == [.deepl])
        model.setEnabled("provider.deepl", true)
        #expect(model.editing == nil)
        model.setEnabled("provider.google", true)
        #expect(model.editing == .google)
        model.cancelEdit()
        let id = model.addAI()
        #expect(model.settings.services.last?.id == id && model.settings.services.last?.enabled == false)
        model.setModel("custom:fast", for: id)
        model.setEnabled(id, true)
        model.move(id, to: 1)
        #expect(model.settings.firstAI?.id == id)
        model.removeAI(id)
        #expect(model.settings.firstAI?.id == id, "the first AI cannot be deleted")
        model.removeAI("ai.primary")
        #expect(!model.settings.services.contains { $0.id == "ai.primary" })
        model.move(id, to: -10)
        #expect(model.settings.services.first?.id == id)
        model.move(id, to: 999)
        #expect(model.settings.services.last?.id == id)
        model.setSecondLanguage("ja")
        #expect(model.store.askTranslationSecondLanguage == "ja" && model.secondLanguage == "ja")
        #expect(model.store.askTranslationSettings == model.settings)
        let unchanged = model.settings
        model.setEnabled("missing", true)
        model.setModel("x", for: "device")
        model.removeAI("device")
        model.move("missing", to: 0)
        #expect(model.settings == unchanged)
    }

    @Test func uncheckedFirstAIStaysProtectedAndCheckedAIControlsTheModel() {
        let model = model()
        model.setModel("custom:home", for: "ai.primary")
        model.setEnabled("ai.primary", false)
        let second = model.addAI()
        model.setModel("custom:second", for: second)
        model.setEnabled(second, true)
        #expect(model.settings.firstEnabledAI?.id == second)
        #expect(model.settings.modelReference == "custom:second")
        model.removeAI("ai.primary")
        #expect(model.settings.firstAI?.id == "ai.primary")
        model.removeAI(second)
        #expect(model.settings.firstEnabledAI == nil && model.settings.modelReference == "custom:home")
    }

    @Test func editingKeysKeepsServiceChangesMadeInAnotherWindow() {
        let credentials = AskTestTranslationCredentials([.deepl: .init(key: "k")])
        let launcher = model(credentials)
        let settings = AskTranslationSettingsModel(store: launcher.store, credentials: credentials)
        settings.setEnabled("provider.deepl", true)
        let extra = settings.addAI()
        settings.move(extra, to: 0)
        settings.setModel("custom:fast", for: extra)
        launcher.edit(.deepl)
        #expect(launcher.settings == settings.settings)
        launcher.remove()
        let saved = launcher.store.askTranslationSettings
        #expect(saved.firstAI?.id == extra && saved.firstAI?.modelReference == "custom:fast")
        #expect(saved.services.map(\.id) == settings.settings.services.map(\.id))
        #expect(saved.services.first { $0.provider == .deepl }?.enabled == false)
    }

    @Test func modelOptionsFollowTheTextModelFirst() {
        let providers = [RegisteredProvider(id: "p", name: "Mine",
                                            models: [RegisteredModel(id: "m", name: "Fast", reference: "custom:fast")])]
        let options = AskTranslationSettingsModel.modelOptions(providers: providers, selected: "")
        #expect(options.map(\.value) == ["", "custom:fast"])
        #expect(options[0].label == L("ask.translation.model.follow") && options[1].label == "Mine · Fast")
        let gone = AskTranslationSettingsModel.modelOptions(providers: providers, selected: "custom:gone")
        #expect(gone.last?.value == "custom:gone" && gone.last?.label == L("ask.translation.model.pickAgain"))
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
        model.setEnabled("provider.youdao", true)
        model.edit(.youdao)
        #expect(model.draft.key == "app")
        model.remove()
        #expect(credentials.credentials(for: .youdao) == nil && !model.configured.contains(.youdao))
        #expect(model.settings.services.first { $0.provider == .youdao }?.enabled == false)
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

@Suite("Ask translation provider sheet", .exclusiveUIState)
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
