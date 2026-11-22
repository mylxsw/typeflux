import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @MainActor private final class TranslationStackFixture {
        let device = AskTestTranslationEngine()
        let ai = AskTestTranslationEngine()
        let deepl = AskTestTranslationEngine()
        let dictionary = AskTestWordLookup(answer: .card(AskWordCard(
            headword: "serendipity", translation: "机缘巧合；意外之喜",
            phonetics: [.init(label: "UK", text: "/ˌserənˈdɪpəti/"), .init(label: "US", text: "/ˌserənˈdɪpəti/")],
            senses: [.init(pos: "n.", meanings: ["意外发现珍奇事物的本领", "机缘巧合；意外之喜"])],
            forms: [.init(label: "复数", value: "serendipities")],
            examples: [.init(source: "It was pure **serendipity** that we met.", target: "我们相遇纯属机缘巧合。"),
                       .init(source: "Many discoveries come from **serendipity**.", target: "许多发现源于意外的好运。")],
            synonyms: ["luck", "chance", "fluke", "good fortune"]
        )))
        let store = makeTestWordBook()
        var services: [AskTranslationService] = [.device, .ai(), .provider(.deepl, enabled: true)]
        var delivered: [String] = []

        func install(_ model: AskConversationModel) {
            deepl.response = "DeepL translation"
            let settings = AskTranslationSettings(services: services)
            let plugin = AskTranslatePlugin(onDevice: device, ai: ai, dictionary: dictionary, wordBook: store,
                                            aiName: { "Typeflux Cloud" }, serviceSettings: { settings },
                                            service: { [deepl] _ in deepl }, fanout: AskTranslationFanout(),
                                            serviceName: { service in
                                                switch service.kind {
                                                case .device: L("ask.translation.stack.deviceTitle")
                                                case .ai: service.id == "second" ? "AI · Second model" : "AI · Typeflux Cloud"
                                                case let .provider(provider): provider.title
                                                }
                                            },
                                            detector: AskTestLanguageDetector(language: "en"))
            model.translationSettingsModel = AskTranslationSettingsModel(store: model.modelLibrary.settings,
                                                                         credentials: AskTestTranslationCredentials())
            model.wordBook = AskWordBookRecorder(store: store)
            model.plugins = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
            model.plugins.debounce = .milliseconds(5)
            model.connectWordBook(to: model.plugins)
            model.deliverText = { [weak self] in self?.delivered.append($0) }
        }
    }

    private func translationInput(_ input: String, into launcher: Launcher) async throws {
        for character in input {
            launcher.editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await translationWait {
            launcher.fixture.model.plugins.isPlanCurrent && launcher.fixture.model.plugins.output != nil
        }
    }

    private func translationWait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Translation did not settle")
    }

    @Test func translationStackNumberCopiesTheMatchingResultAndOptionReturnWritesSelection() async throws {
        try await withPasteboard { pasteboard in
            let data = TranslationStackFixture()
            let launcher = try await Launcher(text: "", prepare: data.install)
            defer { launcher.close() }
            try await translationInput("fy serendipity", into: launcher)
            #expect(data.ai.requests.isEmpty && data.deepl.requests.isEmpty && data.dictionary.requests.isEmpty)
            try await launcher.press(Self.tab)
            try await translationWait { launcher.fixture.model.plugins.output?.translation?.target == "ja" }
            #expect(
                data.deepl.requests.isEmpty && data.dictionary.requests.isEmpty,
                "Tab on a preview is still private"
            )
            try await launcher.press(Self.tab, .shift)
            try await translationWait { launcher.fixture.model.plugins.output?.translation?.target == "zh-Hans" }
            try await launcher.press(Self.returnKey)
            try await translationWait { launcher.fixture.model.plugins.output?.translation?.submitted == true }
            #expect(launcher.dismissed == 0 && data.dictionary.requests.count == 1 && data.deepl.requests.count == 1)
            #expect(launcher.fixture.model.plugins.output?.translation?.results.first?.card != nil)
            #expect(!launcher.fixture.model.plugins.selectItem(99))
            #expect(!launcher.fixture.model.plugins.moveSelection(0))
            try await launcher.press(Self.down)
            #expect(launcher.fixture.model.plugins.output?.selectedItem == 1)
            try await launcher.press(Self.up)
            #expect(launcher.fixture.model.plugins.output?.selectedItem == 0)
            try await launcher.press(19, .command) // ⌘2: device follows the pinned card.
            #expect(pasteboard.string(forType: .string) == "[zh-Hans] serendipity" && launcher.dismissed == 1)

            let writeData = TranslationStackFixture()
            let writer = try await Launcher(text: "", selection: "Selected sentence.", prepare: writeData.install)
            defer { writer.close() }
            for character in "fy " {
                writer.editor.insertText(
                    String(character),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            try await translationWait {
                if case .ready = writer.fixture.model.plugins.phase {
                    true
                } else {
                    false
                }
            }
            try await writer.press(Self.returnKey)
            try await translationWait { writer.fixture.model.plugins.output?.translation?.submitted == true }
            #expect(writer.fixture.model.plugins.selectItem(2))
            try await writer.press(Self.returnKey, .option)
            try await translationWait { !writeData.delivered.isEmpty }
            #expect(writeData.delivered == ["DeepL translation"] && writer.dismissed == 1)
        }
    }

    @Test func translationStackCheckedSecondAIOwnsTheCardAndRegeneration() async throws {
        let data = TranslationStackFixture()
        data.services = [.device, .ai(enabled: false), .ai(id: "second"), .provider(.deepl, enabled: true)]
        let launcher = try await Launcher(text: "", prepare: data.install)
        defer { launcher.close() }
        try await translationInput("fy serendipity", into: launcher)
        #expect(data.dictionary.requests.isEmpty && data.ai.requests.isEmpty)
        try await launcher.press(Self.returnKey)
        try await translationWait { launcher.fixture.model.plugins.output?.wordCard != nil }
        let output = try #require(launcher.fixture.model.plugins.output)
        #expect(output.translation?.results.first?.id == "second")
        #expect(output.translation?.results.first?.name == "AI · Second model")
        let deviceCalls = data.device.requests.count
        let providerCalls = data.deepl.requests.count
        try await launcher.press(15, .command)
        try await translationWait { data.dictionary.requests.count == 2 && launcher.fixture.model.plugins.output != nil }
        #expect(data.device.requests.count == deviceCalls && data.deepl.requests.count == providerCalls)
        #expect(launcher.fixture.model.plugins.output?.translation?.results.first?.id == "second")
    }

    @Test func translationStackRegeneratesOnlyTheCardStarsAndCopiesIt() async throws {
        try await withPasteboard { pasteboard in
            let data = TranslationStackFixture()
            let launcher = try await Launcher(text: "", prepare: data.install)
            defer { launcher.close() }
            try await translationInput("fy serendipity", into: launcher)
            try await launcher.press(Self.returnKey)
            try await translationWait { launcher.fixture.model.plugins.output?.wordCard != nil }
            let providerCalls = data.deepl.requests.count
            try await launcher.press(15, .command) // ⌘R
            try await translationWait {
                data.dictionary.requests.count == 2 && launcher.fixture.model.plugins.output != nil
            }
            #expect(
                data.deepl.requests.count == providerCalls,
                "regenerating a card does not call other services again"
            )
            try await launcher.press(1, .command) // ⌘S
            await launcher.fixture.model.wordBookTask?.value
            #expect(launcher.fixture.model.plugins.output?.starred == true)
            let lookup = try #require(launcher.fixture.model.plugins.output?.wordBook)
            #expect(try data.store.entry(forKey: lookup.key)?.isStarred == true)
            try await launcher.press(8, [.command, .shift])
            #expect(pasteboard.string(forType: .string) == launcher.fixture.model.plugins.output?.wordCard?.markdown)
            #expect(launcher.dismissed == 0)
            try await launcher.press(2, .command) // ⌘D
            #expect(launcher.fixture.model.plugins.comparing)
            var opened: [String?] = []
            launcher.fixture.model.openWordBook = { opened.append($0) }
            try await launcher.press(11, .command) // ⌘B
            #expect(opened == [lookup.key] && launcher.dismissed == 1)
        }
    }

    @Test func translationStackDoesNotInsertACardWithoutATargetLanguageMeaning() async throws {
        let data = TranslationStackFixture()
        data.dictionary.answer = .card(AskWordCard(headword: "serendipity"))
        let launcher = try await Launcher(text: "", prepare: data.install)
        defer { launcher.close() }
        try await translationInput("fy serendipity", into: launcher)
        try await launcher.press(Self.returnKey)
        try await translationWait { launcher.fixture.model.plugins.output?.wordCard != nil }
        #expect(launcher.fixture.model.plugins.output?.wordCard?.translatedText == nil)
        try await launcher.press(Self.returnKey, .option)
        #expect(data.delivered.isEmpty && launcher.dismissed == 0)
        #expect(launcher.fixture.model.plugins.output?.action(for: .optionEnter) == nil)
    }

    @Test func translationStackReturnDuringPlanningUsesTheCurrentInput() async throws {
        let data = TranslationStackFixture()
        let launcher = try await Launcher(text: "", prepare: data.install)
        defer { launcher.close() }
        try await translationInput("fy A sentence.", into: launcher)
        data.device.delay = .milliseconds(150)
        launcher.editor.insertText(" Changed.", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await launcher.press(Self.returnKey)
        try await translationWait { launcher.fixture.model.plugins.output?.translation?.submitted == true }
        #expect(data.ai.requests.map(\.text) == ["A sentence. Changed."])
        #expect(data.deepl.requests.map(\.text) == ["A sentence. Changed."])
        #expect(launcher.dismissed == 0)
    }

    @Test func translationStackEditingAfterSubmissionReturnsToPrivatePreview() async throws {
        let data = TranslationStackFixture()
        let launcher = try await Launcher(text: "", prepare: data.install)
        defer { launcher.close() }
        try await translationInput("fy A sentence.", into: launcher)
        try await launcher.press(Self.returnKey)
        try await translationWait { launcher.fixture.model.plugins.output?.translation?.submitted == true }
        let calls = data.ai.requests.count
        launcher.editor.insertText(" More.", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await translationWait { launcher.fixture.model.plugins.output?.translation?.submitted == false }
        #expect(data.ai.requests.count == calls && data.deepl.requests.count == 1)
        try await launcher.press(Self.tab)
        try await translationWait { launcher.fixture.model.plugins.output?.translation?.target == "ja" }
        #expect(data.ai.requests.count == calls && data.deepl.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func translationStackCopiesCompletedCardBeforeOtherServicesFinish(usingReturn: Bool) async throws {
        try await withPasteboard { pasteboard in
            let data = TranslationStackFixture()
            data.deepl.delay = .seconds(2)
            let launcher = try await Launcher(text: "", prepare: data.install)
            defer { launcher.close() }
            try await translationInput("fy serendipity", into: launcher)
            try await launcher.press(Self.returnKey)
            try await translationWait { launcher.fixture.model.plugins.partial?.wordCard != nil }
            #expect(launcher.fixture.model.plugins.isRunning)
            if usingReturn {
                try await launcher.press(Self.returnKey)
            } else {
                try await launcher.press(18, .command)
            }
            #expect(pasteboard.string(forType: .string) == "机缘巧合；意外之喜")
            #expect(launcher.dismissed == 1)
            #expect(try data.store.count(.all) == 1, "using a partial card keeps it in the word book")
        }
    }

    @Test func translationStackCanStarACardWhileOtherServicesAreRunning() async throws {
        let data = TranslationStackFixture()
        data.deepl.delay = .milliseconds(350)
        let launcher = try await Launcher(text: "", prepare: data.install)
        defer { launcher.close() }
        try await translationInput("fy serendipity", into: launcher)
        try await launcher.press(Self.returnKey)
        try await translationWait { launcher.fixture.model.plugins.partial?.wordCard != nil }
        #expect(launcher.fixture.model.plugins.isRunning)
        try await launcher.press(Self.down)
        #expect(launcher.fixture.model.plugins.partial?.selectedItem == 1)
        try await launcher.press(1, .command)
        await launcher.fixture.model.wordBookTask?.value
        #expect(launcher.fixture.model.plugins.partial?.starred == true)
        try await translationWait { launcher.fixture.model.plugins.output != nil }
        #expect(launcher.fixture.model.plugins.output?.starred == true)
        #expect(launcher.fixture.model.plugins.output?.selectedItem == 1)
    }

    @Test func translationStackSavingProviderKeysRetriesOnlyThatService() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let data = TranslationStackFixture()
        data.deepl.failure = AskTranslationServiceError.notConfigured
        data.ai.delay = .milliseconds(150)
        let launcher = try await Launcher(text: "", prepare: data.install)
        defer { launcher.close() }
        try await translationInput("fy A complete sentence.", into: launcher)
        try await launcher.press(Self.returnKey)
        try await translationWait { launcher.fixture.model.plugins.output?.translation?.submitted == true }
        launcher.window.setContentSize(NSSize(width: AskMetrics.launcherWidth, height: launcher.heights.last ?? 600))
        try await Task.sleep(for: .milliseconds(80))
        let aiCalls = data.ai.requests.count
        let deviceCalls = data.device.requests.count
        #expect(aiCalls == 1)
        try translationClick("ask.translation.result.provider.deepl.recovery", in: launcher.window)
        let model = launcher.fixture.model.translationSettingsModel
        try await translationWait { model.editing == .deepl && launcher.window.attachedSheet != nil }
        model.draft.key = "fixture-key"
        data.deepl.failure = nil
        let sheet = try #require(launcher.window.attachedSheet)
        try await Task.sleep(for: .milliseconds(80))
        try translationClick("ask.translation.provider.save", in: sheet)
        try await translationWait { data.deepl.requests.count == 2 && launcher.fixture.model.plugins.output != nil }
        #expect(data.ai.requests.count == aiCalls && data.device.requests.count == deviceCalls)
        #expect(launcher.fixture.model.plugins.output?.translation?.results.last?.completedText != nil)
        #expect(model.editing == nil)
    }

    private func translationClick(_ identifier: String, in window: NSWindow) throws {
        let point = try AskWorkspaceTestAccessibility.center(identifier: identifier, in: window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            try NSApp.sendEvent(#require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber,
                                                            context: nil, eventNumber: 0, clickCount: 1,
                                                            pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    /// Actual launcher windows on macOS; fixed local engines make captures repeatable.
    @Test func translationStackLauncherSnapshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        for (name, input) in [
            ("word", "serendipity"),
            ("unchecked-first", "serendipity"),
            ("sentence", "The quick fix shipped yesterday, but the root cause is still unknown."),
            ("error", "The quick fix shipped yesterday, but the root cause is still unknown.")
        ] {
            let data = TranslationStackFixture()
            if name == "unchecked-first" {
                data.services = [.device, .ai(enabled: false), .ai(id: "second"), .provider(.deepl, enabled: true)]
            }
            if name == "error" {
                data.deepl.failure = AskTranslationServiceError.quota
            }
            let launcher = try await Launcher(text: "", prepare: data.install)
            defer { launcher.close() }
            data.device.response = input == "serendipity" ? "意外发现" : "快速修复昨天已经发布，但根本原因仍然未知。"
            data.ai.response = "临时修复昨天已经上线，但根本原因还没有查明。"
            data.deepl.response = input == "serendipity" ? "偶然性" : "快速修复已于昨日发布，但根本原因仍然未知。"
            try await translationInput("fy " + input, into: launcher)
            try await launcher.press(Self.returnKey)
            try await translationWait { launcher.fixture.model.plugins.output?.translation?.submitted == true }
            launcher.window.setContentSize(NSSize(
                width: AskMetrics.launcherWidth,
                height: launcher.heights.last ?? 600
            ))
            launcher.window.center()
            launcher.window.makeKeyAndOrderFront(nil)
            for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                launcher.window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(180))
                let view = try #require(launcher.window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 4000)
                try png.write(to: root.appendingPathComponent("launcher-\(name)-\(theme).png"))
                if ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(launcher.window.windowNumber),
                                         root.appendingPathComponent("native-\(name)-\(theme).png").path]
                    try capture.run()
                    capture.waitUntilExit()
                    #expect(capture.terminationStatus == 0, "Native screenshot requires screen recording permission")
                }
            }
        }
    }
}
