import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Translation result polish", .exclusiveUIState)
@MainActor
struct AskTranslationPolishTests {
    var card: AskWordCard {
        AskWordCard(headword: "serendipity", translation: "机缘巧合；意外之喜",
                    phonetics: [.init(label: "UK", text: "/ˌserənˈdɪpəti/"),
                                .init(label: "US", text: "/ˌserənˈdɪpəti/")],
                    senses: [.init(pos: "n.", meanings: ["意外发现珍奇事物的本领", "机缘巧合；意外之喜"])],
                    forms: [.init(label: "复数", value: "serendipities")],
                    examples: [.init(source: "It was pure **serendipity** that we met.", target: "我们相遇纯属机缘巧合。"),
                               .init(source: "Many discoveries come from **serendipity**.", target: "许多发现源于意外的好运。"),
                               .init(source: "A little **serendipity** changed everything.", target: "一点机缘巧合改变了一切。")],
                    synonyms: ["luck", "chance", "fluke", "good fortune"])
    }

    @Test func `collapse defaults and bilingual copy handle every result state`() {
        let states: [AskTranslationResult.State] = [.loading, .streaming("partial"), .done("译文"),
                                                    .done("机缘巧合", card), .failed(.init(message: "", recovery: .none))]
        for state in states {
            let result = AskTranslationResult(service: .ai(), name: "AI", state: state)
            #expect(result.isCollapsed(preference: 0, lookup: true) == (result.card == nil))
            #expect(!result.isCollapsed(preference: 0, lookup: false))
            #expect(result.isCollapsed(preference: 1, lookup: false))
            #expect(!result.isCollapsed(preference: 2, lookup: true))
            #expect(result.isCollapsed(preference: -1, lookup: true) == (result.card == nil))
            #expect(result.copyBoth(original: "原文")?.kind == result.completedText.map { .copy("原文\n\n" + $0) })
        }
        #expect(AskWordCardView.visibleExamples(card, expanded: false).count == 2)
        #expect(AskWordCardView.visibleExamples(card, expanded: true).count == 3)
        #expect(AskWordCardView.visibleExamples(.init(headword: "empty"), expanded: false).isEmpty)
        #expect(AskWordCardView.contentHeight(card, expandedExamples: true) > AskWordCardView.contentHeight(card))
        var oversized = card
        oversized.examples += card.examples
        #expect(oversized.tidied().examples == card.examples)
    }

    @Test func `recovery and screenshot hints are concise in both required languages`() {
        let saved = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(saved) }
        for (language, message, hint) in [(AppLanguage.english, "No API key yet", "you can fix typos, then press ↩"),
                                          (.simplifiedChinese, "还没有填写密钥", "可改错字，再按 ↩")] {
            AppLocalization.shared.setLanguage(language)
            let failure = AskTranslationFailure.presenting(AskTranslationServiceError.notConfigured,
                                                           service: .provider(.google), source: "en", target: "zh-Hans",
                                                           interface: language)
            #expect(failure.message == message)
            #expect(failure.action(for: .provider(.google))?.kind == .configureTranslation(.google))
            #expect(failure.action(for: .provider(.google))?.title
                == (language == .english ? "Configure" : "去配置"))
            #expect(L("ask.translation.panel.screenshot.editHint") == hint)
            #expect(!L("ask.plugin.wordCard.moreExamples", 1).contains("%d"))
        }
    }

    @Test func `copy menu buttons dispatch translation bilingual card and insertion`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            var actions: [AskPluginAction.Kind] = []
            let result = AskTranslationResult(service: .ai(), name: "AI", state: .done("机缘巧合", card))
            let contents = VStack {
                AskTranslationCopyOptions(result: result, original: "serendipity", replacesSelection: true,
                                          onAction: { actions.append($0.kind) })
            }
            try await SettingsBehaviorTestSupport.withWindow(contents, width: 400, height: 250) { window, _ in
                for title in [L("ask.translation.stack.copyTranslation"), L("ask.translation.stack.copyBoth"),
                              L("ask.plugin.action.copyCard"), L("ask.plugin.action.insert")] {
                    try SettingsBehaviorTestSupport.button(title, in: window).press()
                }
                #expect(actions == [.copy("机缘巧合"), .copy("serendipity\n\n机缘巧合"), .copy(card.markdown),
                                    .writeBack("机缘巧合")])
            }
        }
    }

    @Test func `collapse persists per service across hosts and new input`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let first = AskTranslationResult(service: .device, name: "Device", state: .done("First preview"))
            let second = AskTranslationResult(service: .ai(), name: "AI", state: .done("Second result"))
            var stack = AskTranslationStack(results: [first, second], source: "en", target: "fr", interface: .english,
                                            submitted: true, isLookup: false)
            func view() -> some View {
                AskTranslationStackView(stack: stack, original: "Original.", actions: [], defaults: settings.defaults,
                                        onAction: { _ in })
            }
            try await SettingsBehaviorTestSupport.withWindow(view(), width: 452, height: 400) { window, _ in
                try element("ask.translation.result.device.collapse", in: window).press()
                try await SettingsBehaviorTestSupport.wait { settings.defaults.integer(forKey: first.collapseKey) == 1 }
                #expect(settings.defaults.object(forKey: second.collapseKey) == nil)
                #expect(SettingsBehaviorTestSupport.contains("First preview", in: window))
            }
            stack.results[0].state = .done("New preview")
            try await SettingsBehaviorTestSupport.withWindow(view(), width: 452, height: 400) { window, _ in
                let button = try element("ask.translation.result.device.collapse", in: window)
                #expect(button.label == L("ask.translation.stack.expand"))
                #expect(SettingsBehaviorTestSupport.contains("New preview", in: window))
                try button.press()
                try await SettingsBehaviorTestSupport.wait { settings.defaults.integer(forKey: first.collapseKey) == 2 }
            }
            stack.isLookup = true
            try await SettingsBehaviorTestSupport.withWindow(view(), width: 452, height: 400) { window, _ in
                let device = try element("ask.translation.result.device.collapse", in: window)
                let ai = try element("ask.translation.result.ai.primary.collapse", in: window)
                #expect(device.label == L("ask.translation.stack.collapse"))
                #expect(ai.label == L("ask.translation.stack.expand"))
            }
        }
    }

    @Test func `more examples and each phonetic are interactive and reset for A new card`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            var spoken: [AskPluginAction.Kind] = []
            let fixture = WordCardFixture(card: card)
            let view = WordCardFixtureView(fixture: fixture, onAction: { spoken.append($0.kind) })
            try await SettingsBehaviorTestSupport.withWindow(view, width: 420, height: 550) { window, _ in
                #expect(!SettingsBehaviorTestSupport.contains("一点机缘巧合改变了一切。", in: window))
                try element("ask.plugin.wordCard.moreExamples", in: window).press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains("一点机缘巧合改变了一切。", in: window)
                }
                for index in 0 ..< 2 {
                    try element("ask.plugin.wordCard.phonetic.\(index)", in: window).press()
                }
                #expect(spoken == [.speak("serendipity", language: "en-GB"), .speak("serendipity", language: "en-US")])
                var replacement = card
                replacement.headword = "new word"
                fixture.card = replacement
                try await SettingsBehaviorTestSupport.wait {
                    !SettingsBehaviorTestSupport.contains("一点机缘巧合改变了一切。", in: window)
                }
            }
        }
    }

    @Test func `recovery buttons retry only their row skip for the session and open the right form`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let fixture = TranslationPanelFixture()
            defer { fixture.clean() }
            fixture.settings.askTranslationSettings = .init(services: [
                .device,
                .ai(),
                .provider(.deepl, enabled: true)
            ])
            fixture.provider.failure = URLError(.timedOut)
            let model = fixture.model
            model.open(source: .input, text: "The source sentence.")
            model.pinned = true
            model.translate()
            await model.waitForTranslation()
            let controller = AskTranslationPanelController(model: model)
            controller.present()
            let window = try #require(controller.presentedWindow)
            try await Task.sleep(for: .milliseconds(150))
            let deviceCalls = fixture.device.requests.count, aiCalls = fixture.ai.requests.count
            fixture.provider.failure = AskTranslationServiceError.quota
            try element("ask.translation.result.provider.deepl.recovery", in: window).press()
            await model.waitForTranslation()
            #expect(fixture.provider.requests.count == 2)
            #expect(fixture.device.requests.count == deviceCalls && fixture.ai.requests.count == aiCalls)
            try await Task.sleep(for: .milliseconds(150))
            try element("ask.translation.result.provider.deepl.recovery", in: window).press()
            await model.waitForTranslation()
            #expect(model.stack.results.map(\.id) == ["device", "ai.primary"])
            #expect(fixture.provider.requests.count == 2 && fixture.ai.requests.count == aiCalls)
            model.text = "Another source sentence."
            model.translate()
            await model.waitForTranslation()
            #expect(fixture.provider.requests.count == 2)
            model.open(source: .selection, text: "A new session.")
            fixture.provider.failure = AskTranslationServiceError.authentication
            model.pinned = true
            model.translate()
            await model.waitForTranslation()
            try await Task.sleep(for: .milliseconds(150))
            try element("ask.translation.result.provider.deepl.recovery", in: window).press()
            #expect(model.configuration.editing == .deepl)
            try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            #expect(SettingsBehaviorTestSupport.elements(in: sheet)
                .contains { $0.text.contains("DeepL") })
            model.configuration.cancelEdit()
        }
    }

    private func element(_ id: String, in window: NSWindow) throws -> SettingsBehaviorTestSupport.Element {
        try #require(SettingsBehaviorTestSupport.elements(in: window).first {
            $0.value("accessibilityIdentifier") as? String == id
        }, "Missing control: \(id)")
    }
}

@MainActor
private final class WordCardFixture: ObservableObject {
    @Published var card: AskWordCard
    init(card: AskWordCard) {
        self.card = card
    }
}

private struct WordCardFixtureView: View {
    @ObservedObject var fixture: WordCardFixture
    var onAction: (AskPluginAction) -> Void
    var body: some View {
        AskWordCardView(card: fixture.card, language: "en", stackStyle: true, onAction: onAction)
    }
}
