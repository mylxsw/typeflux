import AppKit
import Testing
@testable import Typeflux

@MainActor
final class TranslationPanelFixture {
    let suite = "TranslationPanel-" + UUID().uuidString
    let defaults: UserDefaults
    let settings: SettingsStore
    let device = AskTestTranslationEngine()
    let ai = AskTestTranslationEngine()
    let provider = AskTestTranslationEngine()
    var copied: [String] = []
    var time = Date(timeIntervalSince1970: 1000)
    let book: SQLiteAskWordBookStore
    let directory: URL
    lazy var model: AskTranslationPanelModel = {
        let settings = settings, device = device, ai = ai, provider = provider
        let plugin = AskTranslatePlugin(onDevice: device, ai: ai, wordBook: book,
                                        serviceSettings: { settings.askTranslationSettings },
                                        fanout: AskTranslationFanout(),
                                        engines: { service in
                                            service.kind == .device ? device : service.isAI ? ai : provider
                                        },
                                        serviceName: { $0.id }, detector: AskTestLanguageDetector(language: "en"))
        return AskTranslationPanelModel(settings: settings, plugin: plugin,
                                        configuration: AskTranslationSettingsModel(
                                            store: settings,
                                            credentials: AskTestTranslationCredentials()
                                        ),
                                        now: { [unowned self] in time }, copy: { [unowned self] in copied.append($0) })
    }()

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        book = SQLiteAskWordBookStore(url: directory.appendingPathComponent("words.sqlite"))
        device.response = "Device answer"
        ai.response = "AI answer"
        provider.response = "Provider answer"
    }

    func clean() {
        model.dismiss()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Translation panel session", .exclusiveUIState)
@MainActor
struct AskTranslationPanelModelTests {
    @Test func `input and language changes wait for return and return copies without resubmitting`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        var closed = 0
        model.onDismiss = { closed += 1 }
        model.open(source: .input)
        model.text = "This is a full sentence."
        model.cycleLanguage(1)
        model.perform(.init(kind: .rerun(["source": "en", "target": "fr"]), title: "", symbol: ""))
        #expect(fixture.ai.requests.isEmpty && model.stack.target == "fr")
        #expect(model.isDirty)
        model.submit()
        await model.waitForTranslation()
        #expect(fixture.device.requests.count == 1 && fixture.ai.requests.count == 1)
        #expect(model.stack.submitted && !model.isDirty)
        model.submit()
        #expect(fixture.copied == ["Device answer"] && closed == 1)
        model.pinned = true
        model.submit()
        #expect(fixture.copied.count == 2 && closed == 1 && fixture.ai.requests.count == 1)
        model.text = "An edited sentence."
        #expect(model.output == nil && model.isDirty)
        model.submit()
        await model.waitForTranslation()
        #expect(fixture.ai.requests.count == 2 && fixture.ai.requests.last?.target == "fr")
    }

    @Test func `pin loss of focus and escape follow the two step policy`() {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        var closes = 0
        model.onDismiss = { closes += 1 }
        model.lostFocus()
        #expect(closes == 1)
        model.pinned = true
        model.text = "Original"
        model.lostFocus()
        #expect(closes == 1)
        model.escape()
        #expect(model.text.isEmpty && closes == 1 && model.pinned)
        model.escape()
        #expect(closes == 2)
        model.pinned = false
        model.configuration.edit(.deepl)
        model.lostFocus()
        #expect(closes == 2)
        model.configuration.cancelEdit()
        model.escape()
        #expect(closes == 3)
    }

    @Test func `injected clock keeps content until its deadline`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        for preference in AskTranslationKeepState.allCases {
            var settings = fixture.settings.askTranslationSettings
            settings.keepState = preference
            fixture.settings.askTranslationSettings = settings
            model.open(source: .selection, text: "The retained sentence.")
            model.translate()
            await model.waitForTranslation()
            model.dismiss()
            fixture.time += 1
            model.open(source: .input)
            #expect((model.output != nil) == (preference != .none))
            if let seconds = preference.seconds, seconds > 0 {
                model.dismiss()
                fixture.time += seconds
                model.open(source: .input)
                #expect(model.text.isEmpty && model.output == nil)
            }
        }
    }

    @Test func `history restores the draft without sending and can be cleared`() {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        model.history.record("Older")
        model.history.record("Newer")
        model.history.record("Newer")
        #expect(AskTranslationHistory(defaults: fixture.defaults).entries == ["Newer", "Older"])
        model.text = "Unsubmitted draft"
        model.navigateHistory(1)
        #expect(model.text == "Unsubmitted draft")
        model.navigateHistory(-1)
        #expect(model.text == "Newer")
        model.navigateHistory(-1)
        model.navigateHistory(-1)
        #expect(model.text == "Older")
        model.navigateHistory(1)
        model.navigateHistory(1)
        #expect(model.text == "Unsubmitted draft")
        #expect(fixture.ai.requests.isEmpty)
        model.chooseHistory("Older")
        #expect(model.text == "Older")
        model.clearHistory()
        model.navigateHistory(-1)
        #expect(model.history.entries.isEmpty && fixture.defaults.object(forKey: AskTranslationHistory.key) == nil)
        model.history.record("  ")
        for index in 0 ..< 105 {
            model.history.record("Input \(index)")
        }
        #expect(model.history.entries.count == 100)
    }

    @Test func `auto copy uses display slots and never copies failures or the next service instead`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        for preference in AskTranslationAutoCopy.allCases {
            var settings = fixture.settings.askTranslationSettings
            settings.services = [.device, .ai(), .provider(.deepl, enabled: true)]
            settings.autoCopy = preference
            fixture.settings.askTranslationSettings = settings
            model.open(source: .selection, text: "The complete original sentence.")
            fixture.copied = []
            model.translate()
            await model.waitForTranslation()
            let expected: [String] = switch preference {
            case .none: []
            case .original: [model.text]
            case .first: ["Device answer"]
            case .second: ["AI answer"]
            case .third: ["Provider answer"]
            }
            #expect(fixture.copied == expected)
        }
        var settings = fixture.settings.askTranslationSettings
        settings.autoCopy = .second
        fixture.settings.askTranslationSettings = settings
        fixture.ai.failure = URLError(.timedOut)
        model.open(source: .selection, text: "A failed service sentence.")
        fixture.copied = []
        model.translate()
        await model.waitForTranslation()
        #expect(fixture.copied.isEmpty)
        model.copy(number: 0)
        model.copy(number: 99)
        model.copy(number: 2)
        #expect(fixture.copied.isEmpty)
        let results = model.stack.results
        #expect(AskTranslationAutoCopy.third.text(original: "", results: Array(results.prefix(1))) == nil)
        #expect(AskTranslationAutoCopy.original.text(original: "", results: []) == nil)
    }

    @Test func `selection commands star copy regenerate and swap use the current results`() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        let card = AskWordCard(headword: "serendipity", translation: "Happy accident",
                               senses: [.init(pos: "n.", meanings: ["A fortunate discovery"])])
        let lookup = AskWordBookLookup(headword: card.headword, source: "en", target: "fr", card: card)
        let result = AskPluginOutput(body: "Happy accident", original: "serendipity", meta: [], source: "AI",
                                     actions: [AskTranslatePlugin.starAction(lookup, starred: false),
                                               AskTranslatePlugin.copyAction(card.markdown, shortcut: .shiftCommandC),
                                               AskTranslatePlugin.openWordBookAction(key: lookup.key)], wordCard: card,
                                     translation: .init(
                                         results: [.init(
                                             service: .ai(),
                                             name: "AI",
                                             state: .done("Happy accident", card)
                                         ),
                                         .init(
                                             service: .device,
                                             name: "Device",
                                             state: .done("Other")
                                         )],
                                         source: "en",
                                         target: "fr",
                                         interface: .english,
                                         submitted: true,
                                         isLookup: true
                                     ), wordBook: lookup)
        model.importLauncher(result)
        #expect(model.pinned && !model.isDirty && model.source == .launcher)
        #expect(model.select("missing") == false)
        #expect(model.select("device"))
        var inserted: [String] = []
        var spoken: [String] = []
        var keys: [String?] = []
        var opened: [URL] = []
        var settingsOpened = 0
        model.onInsert = { inserted.append($0) }
        model.onSpeak = { spoken.append($0 + ":" + $1) }
        model.onWordBook = { keys.append($0) }
        model.onSettings = { settingsOpened += 1 }
        model.onOpenURL = { opened.append($0) }
        model.shortcut(.optionEnter)
        #expect(inserted == ["Other"])
        model.moveSelection(-1)
        model.moveSelection(-10)
        model.shortcut(.commandS)
        await model.wordBookTask?.value
        #expect(try fixture.book.entry(forKey: lookup.key)?.isStarred == true)
        model.shortcut(.shiftCommandC)
        model.shortcut(.commandB)
        model.perform(.init(kind: .speak("word", language: "en"), title: "", symbol: ""))
        model.perform(.init(kind: .manageTranslationLanguages, title: "", symbol: ""))
        model.perform(.init(kind: .openSettings, title: "", symbol: ""))
        model.perform(.init(kind: .compare, title: "", symbol: ""))
        #expect(fixture.copied.last == card.markdown && keys == [lookup.key] && spoken == ["word:en"])
        #expect(opened == [AskTranslationSettingsModel.languagePackagesURL] && settingsOpened == 1)
        model.shortcut(.commandR)
        await model.waitForTranslation()
        #expect(fixture.ai.requests.count == 1)
        model.swapLanguages()
        await model.waitForTranslation()
        #expect(model.text == "AI answer")
        #expect(fixture.ai.requests.last?.source == "fr" && fixture.ai.requests.last?.target == "en")
        model.cycleLanguage(1)
        await model.waitForTranslation()
        #expect(model.targetLanguage != "en")
        model.perform(.init(kind: .configureTranslation(.deepl), title: "", symbol: ""))
        #expect(model.configuration.editing == .deepl)
        model.clear()
        model.submit()
        model.translate()
        model.moveSelection(1)
        model.shortcut(.commandS)
        await model.wordBookTask?.value
        model.swapLanguages()
        #expect(model.output == nil)
    }

    @Test func `cancelled runs and handoffs cannot overwrite edited input`() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        fixture.ai.delay = .milliseconds(50)
        model.text = "First sentence."
        model.translate()
        let task = Task { await model.waitForTranslation() }
        model.text = "Second sentence."
        await task.value
        #expect(model.output == nil && !model.running && model.text == "Second sentence.")
        model.translate()
        await model.waitForTranslation()
        let result = try #require(model.output)
        let id = UUID()
        var cancelled = 0
        let handoff = AskPluginHandoff(plugin: model.plugin, plan: .init(mode: .onSubmit, title: ""),
                                       request: .init(text: model.text, origin: .argument,
                                                      keyword: AskTranslatePlugin.keywords[0],
                                                      options: [:], interfaceLanguage: .english), output: result,
                                       running: true,
                                       cancel: { cancelled += 1 })
        model.adoptHandoff(handoff, id: id)
        model.receiveHandoff(.progress(result), id: id)
        #expect(model.running)
        model.receiveHandoff(.done(result), id: id)
        #expect(!model.running)
        model.adoptHandoff(handoff, id: id)
        model.text = "A new edited sentence."
        model.receiveHandoff(.done(result), id: id)
        #expect(model.output == nil && cancelled == 1)
        model.adoptHandoff(handoff, id: id)
        model.receiveHandoff(.failed(.init(message: "sensitive error")), id: id)
        #expect(!model.running && model.notice != "sensitive error")
        model.adoptHandoff(handoff, id: id)
        model.receiveHandoff(.cancelled, id: id)
        #expect(!model.running)
    }
}

extension AskTranslationPanelModelTests {
    @Test func `swapping A private preview still waits for return before sending AI`() {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        fixture.model.importLauncher(.init(body: "Bonjour", original: "A source sentence.", meta: [], source: "Device",
                                           actions: [], translation: .init(
                                               results: [.init(
                                                   service: .device,
                                                   name: "Device",
                                                   state: .done("Bonjour")
                                               )],
                                               source: "en",
                                               target: "fr",
                                               interface: .english,
                                               submitted: false,
                                               isLookup: false
                                           )))
        fixture.model.swapLanguages()
        #expect(fixture.model.text == "Bonjour" && fixture.model.sourceLanguage == "fr" && fixture.model
            .targetLanguage == "en")
        #expect(fixture.ai.requests.isEmpty && fixture.model.isDirty)
    }
}
