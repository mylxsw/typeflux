import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Translation panel v2 redesign", .exclusiveUIState)
@MainActor
struct AskTranslationPanelRedesignTests {
    var card: AskWordCard {
        AskWordCard(headword: "good", translation: "好的；优良的",
                    phonetics: [.init(label: "UK", text: "/ɡʊd/"), .init(label: "US", text: "/ɡʊd/")],
                    senses: [.init(pos: "adj.", meanings: ["好的", "优良的"]),
                             .init(pos: "adv.", meanings: ["好地，很好地（非正式用法）"])],
                    forms: [.init(label: "比较级", value: "better"), .init(label: "最高级", value: "best")],
                    examples: [.init(source: "This is a **good** book.", target: "这是一本**好**书。"),
                               .init(source: "She is **good** at piano.", target: "她**擅长**弹钢琴。"),
                               .init(source: "It's **good** to see you.", target: "见到你真**好**。")],
                    synonyms: ["fine", "nice", "excellent", "decent", "pleasant"])
    }

    @Test func `example translations render emphasis without markdown asterisks`() {
        let text = AskWordCardView.emphasizedTarget("这是一本**好**书。")
        #expect(String(text.characters) == "这是一本好书。")
        let bold = text.runs.filter { $0.foregroundColor != nil }
        #expect(bold.count == 1)
        #expect(String(text[bold[0].range].characters) == "好")
        #expect(String(AskWordCardView.emphasizedTarget("没有标记").characters) == "没有标记")
    }

    @Test func `stack card height grows with content and is not capped like the launcher card`() {
        let full = AskWordCardView.stackContentHeight(card)
        var bare = card
        bare.forms = []
        bare.examples = []
        bare.synonyms = []
        bare.phonetics = []
        let small = AskWordCardView.stackContentHeight(bare)
        #expect(small >= AskWordCardView.stackHeadwordHeight)
        #expect(full > small)
        #expect(AskWordCardView.stackContentHeight(card, expandedExamples: true) > full)
        #expect(AskWordCardView.contentHeight(card, stackStyle: true) == full)
        var long = card
        long.synonyms = (0 ..< 40).map { "synonym\($0)" }
        long.senses = Array(repeating: card.senses[0], count: 12)
        #expect(AskWordCardView.height(long, stackStyle: true) > AskWordCardView.maximumHeight)
        #expect(AskWordCardView.height(long) == AskWordCardView.maximumHeight)
    }

    @Test func `language pair names the detected source and a compare label follows word cards`() {
        let saved = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(saved) }
        AppLocalization.shared.setLanguage(.english)
        var stack = AskTranslationStack(results: [], source: "en", target: "zh-Hans", interface: .english,
                                        submitted: true, isLookup: true)
        #expect(AskTranslationLanguagePair.sourceLabel(stack)
            == L("ask.translation.stack.detected", AskTranslationLanguages.name("en", in: .english)))
        stack.sourceIsAutomatic = false
        #expect(AskTranslationLanguagePair.sourceLabel(stack) == AskTranslationLanguages.name("en", in: .english))
        stack.source = nil
        #expect(AskTranslationLanguagePair.sourceLabel(stack) == L("ask.translation.stack.detect"))
        stack.sourceIsAutomatic = true
        #expect(AskTranslationLanguagePair.sourceLabel(stack) == L("ask.translation.stack.detect"))

        stack.results = [AskTranslationResult(service: .ai(), name: "AI", state: .done("好", card)),
                         AskTranslationResult(service: .device, name: "Device", state: .done("好"))]
        #expect(AskTranslationStackView.showsCompareLabel(stack, before: 1))
        #expect(!AskTranslationStackView.showsCompareLabel(stack, before: 0))
        stack.isLookup = false
        #expect(!AskTranslationStackView.showsCompareLabel(stack, before: 1))
        stack.isLookup = true
        stack.results[0].state = .done("好")
        #expect(!AskTranslationStackView.showsCompareLabel(stack, before: 1))
    }

    @Test func `panel width suits reading and every new string is localized`() {
        #expect(AskTranslationPanelPlacement.width == 640)
        #expect(AskTranslationPanelPlacement.width >= AskTranslationPanelPlacement.minimumSize.width)
        let saved = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(saved) }
        let keys = AskTranslationShortcutSheet.rows.map(\.title) + [
            "ask.translation.stack.compare", "ask.plugin.wordCard.forms", "ask.translation.panel.more",
            "ask.translation.panel.wordBook", "ask.translation.panel.keyboard", "ask.translation.panel.hint.copy",
            "ask.translation.panel.pinned", "ask.translation.panel.recent"
        ]
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            for key in keys {
                #expect(L(key) != key, "\(key) missing in \(language)")
            }
            #expect(!L("ask.translation.panel.copied", "AI").contains("%@"))
            #expect(!L("ask.translation.stack.detected", "English").contains("%@"))
        }
        for source in [AskTranslationPanelSource.input, .selection, .screenshot, .launcher] {
            #expect(NSImage(systemSymbolName: AskTranslationPanelView.symbol(for: source),
                            accessibilityDescription: nil) != nil)
        }
    }

    @Test func `copy and insert flash a footer confirmation that clears itself`() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        var inserted: [String] = []
        model.onInsert = { inserted.append($0) }
        model.open(source: .input, text: "A full source sentence.")
        model.pinned = true
        model.translate()
        await model.waitForTranslation()
        model.copy(number: 2)
        #expect(model.feedback == L("ask.translation.panel.copied", model.stack.results[1].name))
        model.perform(.init(kind: .writeBack("AI answer"), title: "", symbol: ""))
        #expect(inserted == ["AI answer"])
        #expect(model.feedback == L("ask.translation.panel.inserted", model.feedbackName(for: "AI answer")))
        model.perform(.init(kind: .copy("Device answer"), title: "", symbol: ""))
        #expect(fixture.copied.last == "Device answer")
        #expect(model.feedback == L("ask.translation.panel.copied", model.stack.results[0].name))
        try await SettingsBehaviorTestSupport.wait { model.feedback == nil }
    }

    @Test func `feedback names fall back to the selected row or a short preview`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        let long = String(repeating: "x", count: 40)
        #expect(model.feedbackName(for: long) == String(repeating: "x", count: 24) + "…")
        #expect(model.feedbackName(for: " short ") == "short")
        model.open(source: .input, text: "A full source sentence.")
        model.translate()
        await model.waitForTranslation()
        model.output?.selectedItem = 1
        #expect(model.feedbackName(for: "unrelated") == model.stack.results[1].name)
    }

    @Test func `a synonym looks the word up in place and the word book opens without a card`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        var opened: [String?] = []
        model.onWordBook = { opened.append($0) }
        model.open(source: .selection, text: "good")
        model.perform(.init(kind: .runWith("fine"), title: "fine", symbol: "magnifyingglass"))
        #expect(model.text == "fine")
        await model.waitForTranslation()
        #expect(fixture.device.requests.last?.text == "fine")
        #expect(model.history.entries.first == "fine")
        model.clear()
        model.openWordBook()
        #expect(opened == [nil])
    }

    @Test func `word card synonyms and header tools dispatch their actions`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            var actions: [AskPluginAction.Kind] = []
            let star = AskPluginAction(kind: .copy("star"), title: "Star", symbol: "star", shortcut: .commandS)
            let regenerate = AskPluginAction(kind: .copy("regenerate"), title: "Regenerate", symbol: "arrow.clockwise",
                                             shortcut: .commandR)
            let stack = AskTranslationStack(
                results: [AskTranslationResult(service: .ai(), name: "AI", state: .done("好的", card)),
                          AskTranslationResult(service: .device, name: "Device", state: .done("好"))],
                source: "en", target: "zh-Hans", interface: .english, submitted: true, isLookup: true
            )
            let view = AskTranslationStackView(stack: stack, original: "good", actions: [star, regenerate],
                                               selected: 0, viewportHeight: 560, showsLanguageBar: false,
                                               defaults: settings.defaults, onAction: { actions.append($0.kind) })
            try await SettingsBehaviorTestSupport.withWindow(view, width: 640, height: 600) { window, _ in
                #expect(element("ask.translation.languages", in: window) == nil)
                try #require(element("ask.plugin.wordCard.synonym.2", in: window)).press()
                try #require(element("ask.translation.result.ai.primary.star", in: window)).press()
                try #require(element("ask.translation.result.ai.primary.regenerate", in: window)).press()
                #expect(element("ask.translation.result.device.star", in: window) == nil)
                #expect(SettingsBehaviorTestSupport.contains(L("ask.translation.stack.compare"), in: window))
                #expect(actions == [.runWith("excellent"), .copy("star"), .copy("regenerate")])
            }
        }
    }

    @Test func `empty panel lists recent translations and choosing one translates it`() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let enhanced = NSApp.accessibilityAttributeValue(attribute) as? Bool ?? false
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(enhanced, forAttribute: attribute) }
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        model.history.record("Recalled sentence.")
        model.open(source: .input)
        model.pinned = true
        let controller = AskTranslationPanelController(model: model)
        controller.present()
        let window = try #require(controller.presentedWindow)
        try await SettingsBehaviorTestSupport.wait { element("ask.translation.panel.recent.0", in: window) != nil }
        #expect(SettingsBehaviorTestSupport.contains(model.source.title, in: window))
        try #require(element("ask.translation.panel.recent.0", in: window)).press()
        await model.waitForTranslation()
        #expect(model.text == "Recalled sentence.")
        #expect(fixture.device.requests.last?.text == "Recalled sentence.")
        try await SettingsBehaviorTestSupport.wait { element("ask.translation.panel.recent", in: window) == nil }
        model.dismiss()
    }

    private func element(_ id: String, in window: NSWindow) -> SettingsBehaviorTestSupport.Element? {
        SettingsBehaviorTestSupport.elements(in: window).first {
            $0.value("accessibilityIdentifier") as? String == id
        }
    }
}
