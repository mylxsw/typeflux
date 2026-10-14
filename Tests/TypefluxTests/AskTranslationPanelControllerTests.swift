import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Translation panel native UI", .exclusiveUIState)
@MainActor
struct AskTranslationPanelControllerTests {
    private func event(_ window: NSWindow, key: UInt16, flags: NSEvent.ModifierFlags = [],
                       repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "",
                         charactersIgnoringModifiers: "",
                         isARepeat: repeatKey, keyCode: key)!
    }

    @Test func `native window is nonactivating key capable bounded and handles the keyboard`() async throws {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        let controller = AskTranslationPanelController(model: model)
        model.open(source: .input)
        model.text = "A full source sentence."
        controller.present()
        let window = try #require(controller.presentedWindow)
        #expect(window.styleMask.contains(.nonactivatingPanel) && window.canBecomeKey && !window.canBecomeMain)
        #expect(!window.hidesOnDeactivate)
        #expect(try #require(window.screen?.visibleFrame.contains(window.frame)))
        #expect(window.frame.height <= window.screen!.visibleFrame.height * 0.8)
        model.pinned = true
        #expect(controller.handleKeyDown(event(window, key: 36)))
        await model.waitForTranslation()
        #expect(controller.handleKeyDown(event(window, key: 125, flags: .command)))
        #expect(model.output?.selectedItem == 1)
        #expect(controller.handleKeyDown(event(window, key: 126, flags: .command)))
        #expect(controller.handleKeyDown(event(window, key: 8, flags: .command)))
        #expect(fixture.copied.last == "Device answer")
        #expect(controller.handleKeyDown(event(window, key: 18, flags: .command)))
        #expect(controller.handleKeyDown(event(window, key: 35, flags: .command, repeatKey: true)))
        #expect(model.pinned)
        #expect(controller.handleKeyDown(event(window, key: 35, flags: .command)))
        #expect(!model.pinned)
        model.pinned = true
        #expect(controller.handleKeyDown(event(window, key: 48)))
        await model.waitForTranslation()
        #expect(controller.handleKeyDown(event(window, key: 1, flags: [.command, .shift])))
        await model.waitForTranslation()
        #expect(controller.handleKeyDown(event(window, key: 36, flags: .option)))
        model.history.record("Recalled")
        (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(controller.handleKeyDown(event(window, key: 126)))
        #expect(controller.handleKeyDown(event(window, key: 51, flags: .command)))
        #expect(model.text.isEmpty)
        controller.refreshLayout()
        #expect(controller.handleKeyDown(event(window, key: 125)))
        #expect(!controller.handleKeyDown(event(window, key: 36, flags: .shift)))
        let unrelated = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        #expect(!controller.handleKeyDown(event(unrelated, key: 53)))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: unrelated))
        #expect(controller.isPresented)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(fixture.defaults.dictionary(forKey: "ask.translation.panel.origin") != nil)
        controller.refreshLayout()
        controller.focus()
        #expect(controller.handleKeyDown(event(window, key: 53)))
        #expect(!controller.isPresented)
        #expect(!controller.handleKeyDown(event(window, key: 53)))
        unrelated.close()
    }

    @Test func `sentence word error and screenshot panels render in both appearances`() async throws {
        _ = NSApplication.shared
        let savedLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(savedLanguage) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        let controller = AskTranslationPanelController(model: model)
        let original = "The quick fix shipped yesterday, but the root cause is still unknown."
        let card = AskWordCard(headword: "serendipity", translation: "机缘巧合",
                               phonetics: [
                                   .init(label: "UK", text: "/ˌserənˈdɪpəti/"),
                                   .init(label: "US", text: "/ˌserənˈdɪpəti/")
                               ],
                               senses: [.init(pos: "n.", meanings: ["意外发现美好事物的运气；机缘巧合"])],
                               forms: [.init(label: "复数", value: "serendipities")],
                               examples: [.init(source: "It was pure serendipity that we met.", target: "我们相遇纯属机缘巧合。"),
                                          .init(
                                              source: "Science often advances through serendipity.",
                                              target: "科学常常因偶然发现而进步。"
                                          ), .init(
                                              source: "A little **serendipity** changed everything.",
                                              target: "一点机缘巧合改变了一切。"
                                          )],
                               synonyms: ["chance", "luck"])
        for (appearance, mode) in [("dark", AppearanceMode.dark), ("light", .light)] {
            fixture.settings.appearanceMode = mode
            for name in ["panel", "word", "error", "shot"] {
                let isWord = name == "word"
                let text = isWord ? "serendipity" : name == "shot"
                    ? "Deploy the patch behind the feature flag first. Roll back if error rates rise above 1%." :
                    original
                var rows: [AskTranslationResult] = [
                    .init(service: isWord ? .ai() : .device,
                          name: isWord ? "AI · Typeflux Cloud" : L("ask.translation.stack.deviceTitle"),
                          state: .done(
                              isWord ? "机缘巧合" : name == "shot" ? "先在功能开关后面部署补丁。如果错误率升到 1% 以上就回滚。" :
                                  "快速修复昨天已发布，但根本原因仍不清楚。",
                              isWord ? card : nil
                          )),
                    .init(service: isWord ? .device : .ai(),
                          name: isWord ? L("ask.translation.stack.deviceTitle") : "AI · Typeflux Cloud",
                          state: .done(isWord ? "意外发现" : name == "shot" ? "先把补丁部署在功能开关后面；错误率超过 1% 就回滚。" :
                              "临时修复昨天已经上线了，但问题的根本原因还没有查明。")),
                    .init(service: .provider(.deepl), name: "DeepL", state: name == "error"
                        ? .failed(.init(message: L("ask.translation.error.quota"), recovery: .skip))
                        :
                        .done(isWord ? "偶然发现" : name == "shot" ? "首先在功能标志后面部署补丁。如果错误率上升到 1% 以上，则回滚。" :
                            "快速修复已于昨日发布，但根本原因仍然未知。"))
                ]
                rows.append(.init(service: .provider(.youdao), name: L("ask.translation.provider.youdao"),
                                  state: .done(isWord ? "机缘巧合；意外的好运" : name == "shot"
                                      ? "首先在特性标志后部署补丁。如果错误率超过1%，就回滚。"
                                      : "快速修复昨天发布了，但根本原因仍然未知。")))
                if name == "error" {
                    rows.append(.init(service: .provider(.google), name: "Google", state: .failed(.init(
                        message: L("ask.translation.error.notConfigured"), recovery: .configure
                    ))))
                }
                let lookup = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: card)
                let output = AskPluginOutput(body: rows[0].text ?? "", original: text, meta: [], source: rows[0].name,
                                             actions: [AskTranslatePlugin.copyAction(
                                                 rows[0].text ?? "",
                                                 shortcut: .enter
                                             ),
                                             AskTranslatePlugin.starAction(lookup, starred: false),
                                             AskTranslatePlugin.copyAction(
                                                 card.markdown,
                                                 shortcut: .shiftCommandC
                                             ),
                                             AskTranslatePlugin.regenerateAction("ai.primary"),
                                             AskTranslatePlugin.openWordBookAction(key: nil)],
                                             wordCard: isWord ? card : nil,
                                             translation: .init(
                                                 results: rows,
                                                 source: "en",
                                                 target: "zh-Hans",
                                                 interface: .simplifiedChinese,
                                                 submitted: true,
                                                 isLookup: isWord
                                             ))
                model.open(source: name == "word" ? .selection : name == "shot" ? .screenshot : .input,
                           text: text, image: name == "shot" ? NSImage(cgImage: translationPanelImage().image,
                                                                       size: NSSize(width: 220, height: 60)) : nil,
                           lines: name == "shot" ? 2 : 0)
                let id = UUID()
                model.adoptHandoff(.init(
                    plugin: model.plugin,
                    plan: .init(mode: .onSubmit, title: ""),
                    request: .init(text: text, origin: .argument, keyword: AskTranslatePlugin.keywords[0],
                                   options: [:], interfaceLanguage: .simplifiedChinese),
                    output: output,
                    running: false,
                    cancel: {}
                ), id: id)
                model.receiveHandoff(.done(output), id: id)
                model.pinned = true
                controller.present()
                try await Task.sleep(for: .milliseconds(140))
                let window = try #require(controller.presentedWindow)
                let host = try #require(window.contentView)
                host.layoutSubtreeIfNeeded()
                window.display()
                host.displayIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(120))
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    if ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                             URL(fileURLWithPath: directory)
                                                 .appendingPathComponent("native-" + name + "-" + appearance + ".png")
                                                 .path]
                        try process.run(); process.waitUntilExit()
                        #expect(process.terminationStatus == 0)
                    }
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 1000)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS"] {
                    let path = URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + appearance + ".png")
                    try png.write(to: path)
                }
                model.dismiss()
            }
        }
    }
}

extension AskTranslationPanelControllerTests {
    @Test func `command P moves the real launcher preview into A pinned panel without sending AI`() async throws {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let ask = try AskTestFixture(authenticated: false)
        let launcher = AskConversationWindowController(settings: fixture.settings, model: ask.model)
        defer { launcher.dismissLauncher(); ask.model.resetSession() }
        let panel = AskTranslationPanelController(model: fixture.model)
        let entry = AskTranslationPanelCoordinator(model: fixture.model, controller: panel,
                                                   injector: TranslationPanelInjector(),
                                                   recognizer: TranslationPanelRecognizer())
        ask.model.onMoveTranslationToPanel = { session, close in entry.moveFromLauncher(session, closeLauncher: close) }
        var prepared = false
        launcher.showLauncher(then: { prepared = true })
        try await ask.wait { prepared }
        let session = AskPluginSession(plugins: [fixture.model.plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        ask.model.plugins = session
        ask.model.launcherDraft.text = "The source from the launcher."
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: ask.model.launcherDraft.text, selection: nil, language: .english)
        try await ask.wait { session.output?.translation != nil }
        let window = try #require(launcher.launcherWindow)
        NSApp.sendEvent(event(window, key: 35, flags: .command))
        #expect(panel.isPresented && fixture.model.pinned && fixture.model.source == .launcher)
        #expect(fixture.model.text == "The source from the launcher." && fixture.ai.requests.isEmpty)
        #expect(!window.isVisible)
    }
}

extension AskTranslationPanelControllerTests {
    @Test func `sentence panel fits three and four result rows without a blank block above the footer`() async throws {
        _ = NSApplication.shared
        let enhanced = NSApp.accessibilityAttributeValue(.init(rawValue: "AXEnhancedUserInterface")) as? Bool ?? false
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(enhanced, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        model.open(source: .input, text: "A short source sentence.")
        model.pinned = true
        let controller = AskTranslationPanelController(model: model)
        var threeRowHeight: CGFloat = 0
        for count in [3, 4] {
            let rows = (0 ..< count).map { index in
                AskTranslationResult(service: .ai(id: "row.\(index)"), name: "AI \(index)",
                                     state: .done("A short translated sentence."))
            }
            model.output = .init(body: "A short translated sentence.", original: model.text, meta: [], source: "AI",
                                 actions: [], translation: .init(results: rows, source: "en", target: "fr",
                                                                 interface: .english, submitted: true, isLookup: false))
            if !controller.isPresented {
                controller.present()
            }
            try await Task.sleep(for: .milliseconds(250))
            let window = try #require(controller.presentedWindow)
            let controls = SettingsBehaviorTestSupport.elements(in: window)
            let lastRow = try #require(controls.first {
                $0.value("accessibilityIdentifier") as? String == "ask.translation.result." + rows[count - 1].id
            })
            #expect(lastRow.frame.height > 0)
            let bottomInset = lastRow.frame.minY - window.frame.minY
            #expect(bottomInset >= 28 && bottomInset <= 48,
                    "Only the 28-point footer and normal spacing follow the last row")
            if count == 3 {
                threeRowHeight = window.frame.height
            } else {
                #expect(window.frame.height > threeRowHeight + 40 && window.frame.height < threeRowHeight + 90)
            }
            #expect(window.frame.height <= window.screen!.visibleFrame.height * 0.8)
        }
    }

    @Test func `moving the current result scrolls inside the height limit`() async throws {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        var settings = fixture.settings.askTranslationSettings
        settings.maxHeight = .sixty
        fixture.settings.askTranslationSettings = settings
        let model = fixture.model
        let rows = (0 ..< 14).map { index in
            AskTranslationResult(service: .ai(id: "row.\(index)"), name: "AI \(index)",
                                 state: .done(String(repeating: "A paragraph of translated text. ", count: 8)))
        }
        try model.importLauncher(.init(
            body: #require(rows[0].text),
            original: "A source sentence.",
            meta: [],
            source: "AI",
            actions: [],
            translation: .init(results: rows, source: "en", target: "fr", interface: .english,
                               submitted: true, isLookup: false)
        ))
        let controller = AskTranslationPanelController(model: model)
        controller.present()
        let window = try #require(controller.presentedWindow)
        try await Task.sleep(for: .milliseconds(150))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let content = try #require(window.contentView)
        let scroll = try #require(scrollViews(content).first {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 50
        })
        let before = scroll.contentView.bounds.origin.y
        model.moveSelection(13)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.output?.selectedItem == 13)
        #expect(scroll.contentView.bounds.origin.y != before)
        #expect(window.frame.height <= window.screen!.visibleFrame.height * 0.6)
    }
}
