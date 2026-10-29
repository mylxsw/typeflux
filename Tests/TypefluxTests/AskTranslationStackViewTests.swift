import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Translation stack presentation", .exclusiveUIState)
@MainActor
struct AskTranslationStackViewTests {
    @Test func resultActionsUseTheFirstItemForReturnAndTheSelectedItemForInsertion() {
        let first = AskTranslationResult(service: .device, name: "Device", state: .done("first"))
        let ai = AskTranslationResult(service: .ai(), name: "AI", state: .done("second"))
        let failure = AskTranslationResult(service: .provider(.deepl), name: "DeepL",
                                           state: .failed(.init(message: "quota", recovery: .skip)))
        let stack = AskTranslationStack(results: [first, ai, failure], source: "en", target: "fr", interface: .english,
                                        submitted: true, isLookup: false)
        var output = AskPluginOutput(body: "first", original: "Original", meta: [], source: "Device",
                                     actions: [AskTranslatePlugin.copyAction("first", shortcut: .enter)],
                                     translation: stack)
        output.selectedItem = 1
        #expect(output.action(for: .enter)?.kind == .copy("first"))
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("second"))
        #expect(output.action(for: .commandC)?.kind == .copy("second"))
        #expect(output.action(for: .commandR) != nil)
        output.selectedItem = 2
        #expect(output.action(for: .commandC) == nil && output.action(for: .optionEnter) == nil)
        output.selectedItem = 99
        #expect(output.action(for: .optionEnter) == nil)
        let display = AskPluginDisplay(
            title: "Translation",
            symbol: "translate",
            phase: .done(.init(mode: .onSubmit, title: ""), output)
        )
        #expect(AskPluginResultsView.hint(for: display) == L("ask.translation.stack.hint"))
        #expect(AskPluginResultsView
            .cardHeight(output: output, failure: nil, comparing: false) == AskTranslationStackView.height(stack))
        #expect(AskTranslationStackView.height(stack, comparing: true) > AskTranslationStackView.height(stack))
        let ready = AskPluginDisplay(title: "Translation", symbol: "translate",
                                     phase: .ready(.init(mode: .onSubmit, title: "")), translation: true)
        #expect(AskPluginResultsView.mainHeight(ready) == AskPluginResultsView.rowHeight + 38)
    }

    @Test func configurationLanguageManagementAndSwapReachTheLauncher() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.translationSettingsModel = AskTranslationSettingsModel(store: model.modelLibrary.settings,
                                                                     credentials: AskTestTranslationCredentials())
        #expect(model.performPluginAction(.init(kind: .configureTranslation(.deepl), title: "", symbol: "")) == .stay)
        #expect(model.translationSettingsModel.editing == .deepl)
        model.translationSettingsModel.cancelEdit()
        var opened: [URL] = []
        model.openURL = { opened.append($0) }
        #expect(model.performPluginAction(.init(kind: .manageTranslationLanguages, title: "", symbol: "")) == .stay)
        #expect(opened == [AskTranslationSettingsModel.languagePackagesURL])
        let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: nil,
                                        detector: AskTestLanguageDetector(language: "en"))
        model.plugins = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
        model.plugins.debounce = .zero
        model.plugins.enter(AskTranslatePlugin.keywords[0])
        model.plugins.update(text: "Original.", selection: nil, language: .english)
        for _ in 0 ..< 200 where model.plugins.output == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.performPluginAction(.init(
            kind: .swapTranslation("Bonjour.", source: "fr", target: "en"),
            title: "",
            symbol: ""
        )) == .stay)
        for _ in 0 ..< 200
            where model.plugins.output?.original != "Bonjour." {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.launcherDraft.text == "Bonjour.")
        #expect(model.plugins.output?.translation?.source == "fr" && model.plugins.output?.translation?.target == "en")
        #expect(model.plugins.output?.translation?.submitted == false)
    }

    @Test func rendersEveryResultStateAndSettingsInBothAppearances() async throws {
        _ = NSApplication.shared
        let savedLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(savedLanguage) }
        let card = AskWordCard(headword: "serendipity", translation: "机缘巧合",
                               phonetics: [.init(label: "UK", text: "/ˌserənˈdɪpəti/")],
                               senses: [.init(pos: "n.", meanings: ["意外的好运"])])
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "TranslationStackView-" + UUID().uuidString)!)
        var services = AskTranslationSettings().services
        services.append(.ai(id: "extra", modelReference: "custom:removed", enabled: false))
        settings.askTranslationSettings = .init(services: services)
        let credentials = AskTestTranslationCredentials([.deepl: .init(key: "fixture")])
        let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let rows: [AskTranslationResult] = [
                    .init(service: .ai(), name: "AI · Typeflux Cloud", state: .done("机缘巧合", card)),
                    .init(service: .device, name: L("ask.translation.stack.deviceTitle"), state: .done("意外发现")),
                    .init(
                        service: .provider(.deepl),
                        name: "DeepL",
                        state: .failed(.init(message: L("ask.translation.error.quota"), recovery: .skip))
                    ),
                    .init(
                        service: .provider(.google),
                        name: "Google",
                        state: .failed(.init(message: L("ask.translation.error.notConfigured"), recovery: .configure))
                    ),
                    .init(service: .provider(.youdao), name: "Youdao", state: .loading),
                    .init(service: .ai(id: "extra"), name: "AI · Extra", state: .streaming("A streamed translation"))
                ]
                for (name, results, lookup) in [("word", rows, true), ("sentence", Array(rows.dropFirst()), false),
                                                (
                                                    "saved",
                                                    [.init(
                                                        service: .ai(),
                                                        name: "AI",
                                                        state: .done("机缘巧合", card),
                                                        fromWordBook: true
                                                    )],
                                                    true
                                                ),
                                                ("empty", [], false)] {
                    let stack = AskTranslationStack(
                        results: results,
                        source: name == "empty" ? nil : "en",
                        target: "zh-Hans",
                        interface: language,
                        submitted: true,
                        isLookup: lookup
                    )
                    let actions = [AskTranslatePlugin.regenerateAction("ai.primary"),
                                   AskTranslatePlugin.copyAction(card.markdown, shortcut: .shiftCommandC),
                                   AskTranslatePlugin.openWordBookAction(key: nil),
                                   AskTranslatePlugin.starAction(
                                       .init(headword: "serendipity", source: "en", target: "zh-Hans", card: card),
                                       starred: true
                                   )]
                    let view = AskTranslationStackView(
                        stack: stack,
                        original: "Original",
                        actions: actions,
                        starred: true,
                        comparing: name == "sentence",
                        onAction: { _ in }
                    )
                    .padding(16).background(StudioTheme.background)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    try await render(
                        view,
                        appearance: appearance,
                        size: NSSize(width: AskMetrics.launcherWidth, height: 480),
                        name: "stack-\(language.rawValue)-\(name)-\(theme)"
                    )
                }
                let view = AskTranslationSettingsView(settings: settings, library: library, credentials: credentials)
                    .padding(24).background(StudioTheme.background)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                try await render(view, appearance: appearance, size: NSSize(width: 840, height: 760),
                                 name: "settings-\(language.rawValue)-\(theme)")
                var checkedServices = services
                checkedServices[1].enabled = false
                checkedServices[checkedServices.count - 1].enabled = true
                settings.askTranslationSettings = .init(services: checkedServices)
                let checkedView = AskTranslationSettingsView(settings: settings, library: library, credentials: credentials)
                    .padding(24).background(StudioTheme.background)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                try await render(checkedView, appearance: appearance, size: NSSize(width: 840, height: 760),
                                 name: "settings-unchecked-\(language.rawValue)-\(theme)")
                settings.askTranslationSettings = .init(services: services)
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance.Name, size: NSSize, name: String) async throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        if name.hasPrefix("settings-") {
            let elements = SettingsBehaviorTestSupport.elements(in: host)
            #expect(SettingsBehaviorTestSupport.contains(L("ask.translation.stack.deviceTitle"), in: host))
            let removedCopy = ["On this Mac · installed languages", "不出本机 · 本机语言包",
                               "Enabled services translate concurrently", "勾选的服务会同时翻译"]
            #expect(!elements.contains { element in removedCopy.contains { element.text.contains($0) } })
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
            if name.hasPrefix("settings-"), ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                     root.appendingPathComponent("native-" + name + ".png").path]
                try capture.run()
                capture.waitUntilExit()
                #expect(capture.terminationStatus == 0)
            }
        }
    }
}
