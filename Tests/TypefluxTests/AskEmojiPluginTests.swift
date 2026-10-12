import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
// UI fixtures share the same exclusive-state scope.
// swiftlint:disable:next type_body_length
struct AskEmojiPluginTests {
    private func request(_ text: String, options: [String: String] = [:],
                         origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        .init(
            text: text,
            origin: origin,
            keyword: AskEmojiPlugin.keywords[0],
            options: options,
            interfaceLanguage: .english
        )
    }

    private func plugin() -> AskEmojiPlugin {
        AskEmojiPlugin(service: EmojiSearchTests.service())
    }

    private func settle(_ session: AskPluginSession) async throws {
        for _ in 0 ..< 1000
            where session.output == nil || !session.isPlanCurrent {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.output != nil)
    }

    @Test func `registration and legacy conflicts`() {
        #expect(AskPluginRegistry.pluginIDs.contains(AskEmojiPlugin.id))
        let defaults = AskPluginRegistry.keywords(saved: nil, known: nil)
        #expect(defaults.first { $0.pluginID == AskEmojiPlugin.id }?.allKeywords == ["emoji", "表情"])
        let reserved = AskPluginRegistry.keywords(saved: nil, known: nil, reserved: ["emoji"])
        #expect(reserved.first { $0.pluginID == AskEmojiPlugin.id }?.allKeywords == ["表情"])
        let both = AskPluginRegistry.keywords(saved: nil, known: nil, reserved: ["emoji", "表情"])
        #expect(!both.contains { $0.pluginID == AskEmojiPlugin.id })
        let saved = [AskKeyword(keyword: "custom", pluginID: AskEmojiPlugin.id, enabled: false)]
        let preserved = AskPluginRegistry.keywords(saved: saved, known: AskPluginRegistry.coveredGroups)
        #expect(preserved == saved)
        #expect(AskKeywordKind(pluginID: AskEmojiPlugin.id) == .emoji)
        #expect(AskKeywordKind.emoji.pluginID == AskEmojiPlugin.id)
        #expect(!AskKeywordKind.emoji.title.isEmpty && !AskKeywordKind.emoji.hint.isEmpty)
        #expect(AskKeywordKind.emoji.symbol == "face.smiling")
        #expect(!AskKeywordListPresentation.name(of: AskEmojiPlugin.keywords[0]).isEmpty)
        #expect(!AskKeywordListPresentation.summary(
            of: AskEmojiPlugin.keywords[0],
            interface: .english,
            secondLanguage: "zh"
        ).isEmpty)
    }

    @Test func `live plugin and actions`() async throws {
        let plugin = plugin()
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        #expect(plugin.defaultKeywords == AskEmojiPlugin.keywords)
        #expect(plugin.symbol == "face.smiling" && !plugin.placeholder(selectionLines: 2).isEmpty)
        #expect(plugin.chipDetail(for: AskEmojiPlugin.keywords[0], language: .english) == nil)
        let plan = await plugin.plan(request("thanks"))
        #expect(plan.mode == .live && plan.debounce == .milliseconds(60))
        #expect(plugin.nextOptions(after: plan, request: request(""), step: 1) == nil)
        let output = try await plugin.run(request("🙏🏽"), plan: plan)
        #expect(output.items.count == 1)
        #expect(output.action(for: .enter)?.kind == .copy("🙏🏽"))
        #expect(output.action(for: .commandC)?.kind == .copy("🙏🏽"))
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("🙏🏽"))
        #expect(output.emoji?.results.first?.sequence == "🙏🏽")
        let empty = try await plugin.run(request("zzzzzz"), plan: plan)
        #expect(empty.items.isEmpty && empty.action(for: .enter) == nil)
        let selection = try await plugin.run(request("smile", origin: .selection), plan: plan)
        #expect(selection.items.count == EmojiSearchTests.catalog.entries.count)
        let selected = try await plugin.run(
            request("", options: ["selectedID": EmojiSearchTests.catalog.entries[2].id, "selectedQuery": ""]),
            plan: plan
        )
        #expect(selected.selectedItem == 2)
        #expect(!AskEmojiPlugin.reason("typo:smiel → smile").isEmpty)
        #expect(!AskEmojiPlugin.reason("intent:1").isEmpty)
        let failed = AskEmojiPlugin(service: EmojiSearchService(load: { throw CocoaError(.fileReadCorruptFile) }))
        await #expect(throws: AskPluginFailure.self) { try await failed.run(request("x"), plan: plan) }
    }

    @Test func `persisted usage and variants`() throws {
        let name = "emoji-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("bad".utf8), forKey: EmojiUsageStore.key)
        let store = EmojiUsageStore(defaults: defaults)
        #expect(store.value == EmojiUsage())
        for index in 0 ..< 55 {
            store.record(id: String(index), sequence: "😊")
        }
        #expect(store.value.recent.count == 50)
        store.record(id: "54", sequence: "🙏🏽")
        #expect(store.value.recent.first?.count == 2)
        store.toggleFavorite("54")
        store.setVariant("🙏🏽", for: "54")
        let reloaded = EmojiUsageStore(defaults: defaults)
        #expect(reloaded.value == store.value)
        store.toggleFavorite("54")
        #expect(store.value.favorites.isEmpty)
        store.clearRecent()
        #expect(store.value.recent.isEmpty && store.value.variants["54"] == "🙏🏽")
    }

    @Test func `session cancels and never uses selection`() async throws {
        let session = AskPluginSession(plugins: [plugin()], keywords: { AskEmojiPlugin.keywords })
        session.enter(AskEmojiPlugin.keywords[0])
        session.update(text: "smile", selection: "secret", language: .english)
        session.update(text: "red heart", selection: "secret", language: .english)
        try await settle(session)
        #expect(session.output?.selected?.actions.first?.kind == .copy("❤️"))
        #expect(session.request?.selection == nil)
        session.update(text: "smile", selection: nil, language: .english)
        #expect(!session.isPlanCurrent)
        _ = session.deactivate()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.output == nil)
    }

    @Test func `model actions and usage`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let plugin = AskEmojiPlugin(service: EmojiSearchTests.service(), usage: { model.emojiUsage.value })
        model.plugins.replacePlugins([plugin])
        model.plugins.enter(AskEmojiPlugin.keywords[0])
        model.launcherDraft.text = "thanks"
        model.plugins.update(text: "thanks", selection: nil, language: .english)
        try await settle(model.plugins)
        let result = try #require(model.plugins.output?.emoji?.results.first)
        model.performEmojiAction(.favorite(result.id))
        try await settle(model.plugins)
        #expect(model.emojiUsage.value.favorites.contains(result.id))
        model.performEmojiAction(.variant(id: result.id, sequence: "🙏🏽"))
        try await settle(model.plugins)
        #expect(model.emojiUsage.value.variants[result.id] == "🙏🏽")
        model.performEmojiAction(.variant(id: result.id, sequence: "invalid"))
        #expect(model.emojiUsage.value.variants[result.id] == "🙏🏽")
        let board = NSPasteboard(name: .init("emoji-test-" + UUID().uuidString))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = board
        defer { AskQuickResults.pasteboard = previous; board.releaseGlobally() }
        #expect(model.selectedEmoji(copying: "wrong") == nil)
        model.copyPluginText("🙏🏽")
        #expect(board.string(forType: .string) == "🙏🏽")
        #expect(model.emojiUsage.value.recent.first?.sequence == "🙏🏽")
        model.performEmojiAction(.clearRecent)
        try await settle(model.plugins)
        #expect(model.emojiUsage.value.recent.isEmpty)
        let action = try #require(model.plugins.output?.action(for: .enter))
        #expect(model.performPluginAction(action) == .close)
        #expect(model.emojiUsage.value.recent.first?.sequence == "🙏🏽")
        model.performEmojiAction(.favorite("missing"))
    }

    @Test func `grid keyboard and input composition`() throws {
        #expect(EmojiGridKeyboard.Key.resolve(code: 36, modifiers: []) == .copy)
        #expect(EmojiGridKeyboard.Key.resolve(code: 76, modifiers: .option) == .insert)
        #expect(EmojiGridKeyboard.Key.resolve(code: 8, modifiers: .command) == .copyAndStay)
        #expect(EmojiGridKeyboard.Key.resolve(code: 123, modifiers: [.function, .numericPad]) == .move(-1))
        #expect(EmojiGridKeyboard.Key.resolve(code: 124, modifiers: []) == .move(1))
        #expect(EmojiGridKeyboard.Key.resolve(code: 125, modifiers: []) == .move(8))
        #expect(EmojiGridKeyboard.Key.resolve(code: 126, modifiers: []) == .move(-8))
        #expect(EmojiGridKeyboard.Key.resolve(code: 48, modifiers: []) == nil)
        #expect(EmojiGridKeyboard.Key.resolve(code: 36, modifiers: .command) == nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView()
        window.contentView = view
        var keys: [EmojiGridKeyboard.Key] = []
        let keyboard = EmojiGridKeyboard(focused: true, onKey: { keys.append($0) })
        let coordinator = keyboard.makeCoordinator()
        coordinator.view = view
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(coordinator.handle(event) == nil)
        #expect(keys == [.copy])
        coordinator.parent.focused = false
        #expect(coordinator.handle(event) != nil)
        var text = ""
        let composer = AskComposerTextView(text: Binding(get: { text }, set: { text = $0 }), placeholder: "",
                                           defersCompositionUpdates: true, onSubmit: {})
        let editor = AskComposerTextView.Editor()
        editor.setMarkedText(
            "开",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let delegate = composer.makeCoordinator()
        delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(text.isEmpty)
        editor.unmarkText()
        delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(text == "开")
    }

    @Test func `insertion fallback and stale actions`() async throws {
        let board = NSPasteboard(name: .init("emoji-insert-" + UUID().uuidString))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = board
        defer { AskQuickResults.pasteboard = previous; board.releaseGlobally() }
        for mode in 0 ... 2 {
            let fixture = try AskTestFixture()
            let model = fixture.model
            defer { model.resetSession() }
            model.plugins.replacePlugins([plugin()])
            model.plugins.enter(AskEmojiPlugin.keywords[0])
            model.launcherDraft.text = "🙏🏽"
            model.plugins.update(text: "🙏🏽", selection: nil, language: .english)
            try await settle(model.plugins)
            let action = try #require(model.plugins.output?.action(for: .optionEnter))
            model.plugins.update(text: "smile", selection: nil, language: .english)
            #expect(model.performPluginAction(action) == .stay)
            #expect(model.emojiUsage.value.recent.isEmpty)
            try await settle(model.plugins)
            #expect(model.performPluginAction(action) == .stay)
            model.copyPluginText("🙏🏽")
            #expect(model.emojiUsage.value.recent.isEmpty)
            model.plugins.update(text: "🙏🏽", selection: nil, language: .english)
            try await settle(model.plugins)
            var delivered: [String] = []
            model.deliverText = mode == 2 ? nil : { text in
                if mode == 1 {
                    throw CocoaError(.featureUnsupported)
                }
                delivered.append(text)
            }
            board.clearContents()
            #expect(model.performPluginAction(action) == .close)
            for _ in 0 ..< 200
                where model.emojiUsage.value.recent.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(model.emojiUsage.value.recent.first?.sequence == "🙏🏽")
            if mode == 0 {
                #expect(delivered == ["🙏🏽"])
            } else {
                #expect(board.string(forType: .string) == "🙏🏽")
            }
        }
    }

    // Exercise each native rendering state with identical window setup.
    // swiftlint:disable:next function_body_length
    @Test func `render empty and results`() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let plugin = AskEmojiPlugin()
        let plan = await plugin.plan(request(""))
        for query in ["", "想表达感谢", "smiel", "zzzzzzz"] {
            var queryRequest = request(query)
            queryRequest.interfaceLanguage = .simplifiedChinese
            let output = try await plugin.run(queryRequest, plan: plan)
            #expect(AskPluginResultsView.cardHeight(output: output, failure: nil, comparing: false) == EmojiResultsView
                .height)
            for scheme in [ColorScheme.light, .dark] {
                let display = AskPluginDisplay(
                    title: plugin.title,
                    symbol: plugin.symbol,
                    phase: .done(plan, output),
                    offersAskAI: false
                )
                let view = VStack(spacing: 0) {
                    HStack {
                        AskKeywordChip(title: "emoji",
                                       symbol: plugin.symbol); Text(
                            query.isEmpty ? L("emoji.placeholder") : query
                        ); Spacer()
                    }
                    .padding(20)
                    AskPluginResultsView(
                        display: display,
                        question: query,
                        onMain: {},
                        onAction: { _ in },
                        onAskAI: {},
                        onHighlight: { _ in }
                    )
                }.frame(width: 700).background(Color(nsColor: .windowBackgroundColor)).environment(
                    \.colorScheme,
                    scheme
                )
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.close() }
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.height > 300)
                if query == "想表达感谢",
                   let directory = ProcessInfo.processInfo.environment["TYPEFLUX_EMOJI_SCREENSHOTS_DIR"],
                   let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let name = scheme == .light ? "emoji-light.png" : "emoji-dark.png"
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
        #expect(EmojiResultsView.nextIndex(0, delta: -8, count: 10) == 0)
        #expect(EmojiResultsView.nextIndex(8, delta: 8, count: 10) == 9)
        #expect(EmojiResultsView.nextIndex(0, delta: 1, count: 0) == nil)
    }
}
