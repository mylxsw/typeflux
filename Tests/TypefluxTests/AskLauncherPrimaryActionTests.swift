import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher primary action", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherPrimaryActionTests {
    typealias Launcher = AskQuickResultsInteractionTests.Launcher

    @Test func emptyContextAttachmentsAndToolsKeepTheirIntentWhileUnavailable() {
        let empty = AskDraft(text: " \n ", screenshot: "capture", selection: "Automatic context")
        let open = AskLauncherPrimaryAction.chat(draft: empty, canSend: false, canOpen: true, loadingAttachments: false)
        #expect(open.mode == .openChat && open.enabled)
        #expect(open.mode.symbol == "bubble.left" && open.hint.contains("↩"))
        let blocked = AskLauncherPrimaryAction.chat(draft: empty, canSend: false, canOpen: false,
                                                    loadingAttachments: false)
        #expect(blocked.mode == .openChat && !blocked.enabled)
        #expect(blocked.hint == L("ask.openChat.wait"))
        let attachments = AskDraft(attachments: [.init(kind: .file, name: "file", text: "text")])
        for draft in [AskDraft(text: "Question"), attachments] {
            let send = AskLauncherPrimaryAction.chat(draft: draft, canSend: true, canOpen: true,
                                                     loadingAttachments: false)
            #expect(send.mode == .askAI && send.enabled && send.mode.symbol == "arrow.up")
            let waiting = AskLauncherPrimaryAction.chat(draft: draft, canSend: false, canOpen: false,
                                                        loadingAttachments: true)
            #expect(waiting.mode == .askAI && !waiting.enabled)
        }
        let tools = AskLauncherPrimaryAction.chat(draft: AskDraft(skills: ["skill"]), canSend: false,
                                                  canOpen: true, loadingAttachments: false)
        #expect(tools.mode == .askAI && !tools.enabled && tools.hint == L("ask.launcher.action.input"))
    }

    @Test func localResultsDescribeTheActualActionEvenWhenChatIsUnavailable() throws {
        let chat = AskLauncherPrimaryAction(mode: .askAI, enabled: false)
        let apps = AskTestAppIndex(AskTestAppIndex.sample.entries)
        let files = AskTestFileIndex.sample
        for query in ["1+1", "2024", "wx", "hetong", "invoice"] {
            let results = try #require(AskQuickResults.resolve(text: query, previous: nil, chinese: true,
                                                               calculator: true,
                                                               sources: .init(apps: apps, files: files)))
            var mutable = results
            for index in mutable.rows.indices {
                mutable.highlighted = index
                let action = AskLauncherPrimaryAction.quickResult(mutable, pending: false, chat: chat)
                if mutable.highlightedRow == .askAI { #expect(action == chat) } else {
                    #expect(action.enabled == mutable.isEnabled(mutable.highlightedRow))
                    #expect(action.mode.symbol == "return" && action.mode.shortcut == nil)
                    #expect(!action.title.isEmpty)
                }
                let pending = AskLauncherPrimaryAction.quickResult(mutable, pending: true, chat: chat)
                #expect(pending.mode == action.mode && !pending.enabled)
                #expect(pending.hint == L("ask.launcher.action.wait"))
            }
        }
        var features = AskQuickResults(apps: [], lead: false)
        features.features = [.init(keyword: .init(keyword: "fy", pluginID: AskTranslatePlugin.id),
                                   title: "Translate", detail: "", symbol: "character")]
        features.highlighted = 0
        #expect(AskLauncherPrimaryAction.quickResult(features, pending: false, chat: chat).title == "Translate")
        let browser = try #require(AskQuickResults.addingBrowsers([
            .init(id: "tab", kind: .tab, browser: .safari, title: "Example", url: "https://example.com")
        ], to: nil))
        var selectedBrowser = browser
        selectedBrowser.highlighted = 0
        let browserAction = AskLauncherPrimaryAction.quickResult(selectedBrowser, pending: false, chat: chat)
        #expect(browserAction.title == L("ask.quick.action.open"))
    }

    @Test func keywordPhasesNeverFallThroughToChat() {
        let copy = AskPluginAction(kind: .copy("result"), title: "Copy result", symbol: "doc", shortcut: .enter)
        let plan = AskPluginPlan(mode: .onSubmit, title: "Translate")
        let output = AskPluginOutput(body: "result", original: "input", meta: [], source: "test", actions: [copy])
        var display = AskPluginDisplay(title: "Translate", symbol: "character", phase: .waiting, offersAskAI: false)
        #expect(!AskLauncherPrimaryAction.plugin(display, current: false, canAskAI: true).enabled)
        let runnable = AskLauncherPrimaryAction.plugin(display, current: false, canAskAI: false,
                                                       canRunWithoutInput: true)
        #expect(runnable.enabled && runnable.mode == .execute(L("ask.launcher.action.run", "Translate")))
        for phase in [AskPluginSession.Phase.ready(plan), .running(plan), .done(plan, output),
                      .failed(plan, .init(message: "failed")), .failed(plan, .init(message: "failed", retry: false)),
                      .failed(plan, .init(message: "failed", retry: false, actions: [copy]))] {
            display.phase = phase
            for current in [false, true] {
                let action = AskLauncherPrimaryAction.plugin(display, current: current, canAskAI: true)
                #expect(action.mode.symbol == "return")
                if !current { #expect(!action.enabled) }
            }
        }
        display.phase = .done(plan, output)
        #expect(AskLauncherPrimaryAction.plugin(display, current: true, canAskAI: false).title == "Copy result")
        display.phase = .running(.init(mode: .onSubmit, title: "Open", actions: [copy]))
        #expect(AskLauncherPrimaryAction.plugin(display, current: true, canAskAI: false).enabled)
        display.hint = .init(keyword: "fy", pluginID: AskTranslatePlugin.id)
        #expect(AskLauncherPrimaryAction.plugin(display, current: false, canAskAI: false).enabled)
        display.hint = .init(keyword: "chat", pluginID: AskOpenChatPlugin.id)
        #expect(AskLauncherPrimaryAction.plugin(display, current: true, canAskAI: true).mode == .openChat)
        display.highlighted = 1; display.offersAskAI = true
        #expect(AskLauncherPrimaryAction.plugin(display, current: true, canAskAI: true).mode == .askAI)
        #expect(!AskLauncherPrimaryAction.plugin(display, current: true, canAskAI: false).enabled)
    }

    @Test(arguments: [false, true])
    func primaryButtonAndReturnOpenTheSameSelectedFile(click: Bool) async throws {
        let host = AskQuickResultsInteractionTests.FileHost()
        let launcher = try await launch("hetong", prepare: host.install)
        defer { launcher.close() }
        let button = try element("ask.launcher.openChat", in: launcher.window)
        #expect(button.value("accessibilityValue") as? String == "return")
        #expect((button.value("accessibilityLabel") as? String)?.contains("合同") == true)
        if click { try await pressButton(in: launcher) } else { try await launcher.press(36) }
        #expect(host.urls == [URL(fileURLWithPath: "/Users/test/Documents/合同", isDirectory: true)])
        #expect(launcher.dismissed == 1 && launcher.fixture.model.launcherDraft.text.isEmpty)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test(arguments: [false, true])
    func primaryButtonAndReturnCopyTheCalculation(click: Bool) async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let launcher = try await launch("1+1")
            defer { launcher.close() }
            #expect(try element("ask.launcher.openChat", in: launcher.window).value("accessibilityLabel") as? String
                == L("ask.launcher.action.copyResult"))
            if click { try await pressButton(in: launcher) } else { try await launcher.press(36) }
            #expect(pasteboard.string(forType: .string) == "2")
            #expect(launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func primaryButtonUsesTheOpenActionMenuInsteadOfSending() async throws {
        let host = AskQuickResultsInteractionTests.FileHost()
        let launcher = try await launch("invoice", prepare: host.install)
        defer { launcher.close() }
        try await launcher.press(125)
        launcher.editor.setSelectedRange(NSRange(location: launcher.editor.string.utf16.count, length: 0))
        try await launcher.press(124)
        try await launcher.press(125)
        try await launcher.press(125)
        #expect(try element("ask.launcher.openChat", in: launcher.window).value("accessibilityLabel") as? String
            == L("ask.quick.action.reveal"))
        try await pressButton(in: launcher)
        #expect(host.revealed.count == 1 && host.urls.isEmpty)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func historyButtonOnlyFillsTheSelectedInputAndEmptyHistoryCannotSend() async throws {
        let launcher = try await launch("")
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.openLauncherInputHistory()
        #expect(!AskComposer(model: model, launcher: true).launcherPrimaryAction.enabled)
        model.recordLauncherInput(destination: .askAI, text: "Previous question")
        try await Task.sleep(for: .milliseconds(60))
        #expect(try element("ask.launcher.openChat", in: launcher.window).value("accessibilityLabel") as? String
            == L("ask.inputHistory.fill"))
        try await pressButton(in: launcher)
        #expect(!model.launcherHistoryMode && model.launcherDraft.text == "Previous question")
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test(arguments: [false, true])
    func keywordButtonCopiesOrMovesTheResultWithoutStartingAChat(popOut: Bool) async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let translation = AskQuickResultsInteractionTests.Translation()
            var windows: [AskResultDocument] = []
            let launcher = try await launch("fy ") { model in
                translation.install(in: model)
                model.presentResultWindow = { windows.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            #expect(model.plugins.isActive)
            #expect(!AskComposer(model: model, launcher: true).launcherPrimaryAction.enabled)
            #expect(!AskComposer(model: model, launcher: true).launcherCanOpenFeatureWindow)
            #expect(find("ask.launcher.featureWindow", in: launcher.window) == nil)
            model.launcherDraft.text = "hello"
            try await launcher.fixture.wait { model.plugins.output?.body == "[zh-Hans] hello" }
            try await Task.sleep(for: .milliseconds(60))
            #expect(try element("ask.launcher.openChat", in: launcher.window).value("accessibilityLabel") as? String
                == L("ask.plugin.action.copy"))
            #expect(find("ask.launcher.featureWindow", in: launcher.window) != nil)
            try await pressButton(popOut ? "ask.launcher.featureWindow" : "ask.launcher.openChat", in: launcher)
            if popOut { #expect(windows.count == 1 && windows[0].body == "[zh-Hans] hello") } else {
                #expect(windows.isEmpty)
            }
            #expect(translation.device.requests.count == 1 && translation.ai.requests.isEmpty)
            #expect(pasteboard.string(forType: .string) == (popOut ? nil : "[zh-Hans] hello"))
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func windowHandoffPreservesOneSubmittedRunAndRejectsStaleResults() async throws {
        let plugin = AskTestPlugin()
        plugin.live = false
        plugin.runDelay = .milliseconds(100)
        let session = AskPluginSessionTests().session(plugin)
        defer { session.deactivate() }
        _ = session.detect(in: "tt input")
        #expect(!session.canHandOff)
        session.update(text: "input", selection: nil, language: .english)
        try await AskQuickSearchSessionTests.wait { if case .ready = session.phase { true } else { false } }
        #expect(!session.canHandOff && session.handOff(to: { _ in }) == nil)
        #expect(session.run() && session.canHandOff)
        var completion: String?
        let handoff = try #require(session.handOff { event in
            if case let .done(output) = event { completion = output.body }
        })
        #expect(handoff.running && handoff.request.text == "input")
        session.deactivate()
        try await AskQuickSearchSessionTests.wait { completion != nil }
        #expect(completion == "done input" && plugin.runs.count == 1)

        plugin.live = true; plugin.runDelay = .zero
        _ = session.detect(in: "tt second")
        session.update(text: "second", selection: nil, language: .english)
        try await AskQuickSearchSessionTests.wait { session.output != nil }
        #expect(session.canHandOff)
        #expect(session.handOff(to: { _ in })?.output?.body == "done second")
        session.update(text: "new input", selection: nil, language: .english)
        #expect(!session.canHandOff && session.handOff(to: { _ in }) == nil)
    }

    @Test func unavailableFeatureWindowShortcutDoesNotOpenChat() async throws {
        let translation = AskQuickResultsInteractionTests.Translation()
        let launcher = try await launch("fy ", prepare: translation.install)
        defer { launcher.close() }
        var opened = 0
        launcher.fixture.model.onShowConversation = { opened += 1 }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: launcher.window.windowNumber, context: nil, characters: "o",
            charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
        launcher.editor.keyDown(with: event)
        #expect(opened == 0 && launcher.fixture.model.plugins.isActive)
        // Physical-key routing must use the same capability check, even without a Latin "o".
        #expect(launcher.editor.onCommandKey?(.commandO) == true)
        #expect(opened == 0 && launcher.fixture.model.plugins.isActive)
    }

    @Test func repeatedReturnDoesNotExecuteAndCommandReturnStillExplicitlyAsksAI() async throws {
        let apps = AskTestAppIndex(AskTestAppIndex.sample.entries)
        let launcher = try await launch("wx", apps: apps)
        defer { launcher.close() }
        let repeatEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: launcher.window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: true, keyCode: 36))
        launcher.editor.keyDown(with: repeatEvent)
        #expect(launcher.opened.isEmpty)
        #expect(launcher.editor.performKeyEquivalent(with: repeatEvent))
        try await launcher.press(36, .command)
        #expect(try await launcher.sentCount() == 1 && launcher.opened.isEmpty)
    }

    @Test func pendingRowsKeepTheirActionDisabledAndNeverSendToAI() async throws {
        let apps = AskTestAppIndex(AskTestAppIndex.sample.entries)
        let launcher = try await launch("wx", apps: apps)
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.launcherDraft.text = "a new question"
        let action = AskComposer(model: model, launcher: true).launcherPrimaryAction
        #expect(!action.enabled && action.mode.symbol == "return")
        // Native Return can arrive before SwiftUI's onChange begins the replacement search.
        _ = launcher.editor.onCommandKey?(.enter)
        #expect(launcher.opened.isEmpty)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

}

extension AskLauncherPrimaryActionTests {
    @Test func historyReturnUsesTheSameReadinessAsItsButton() async throws {
        let launcher = try await launch("")
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.recordLauncherInput(destination: .askAI, text: "Recalled question")
        model.openLauncherInputHistory()
        model.recordingIsActive = { true }
        #expect(!AskComposer(model: model, launcher: true).launcherPrimaryAction.enabled)
        try await launcher.press(36)
        #expect(model.launcherHistoryMode && model.launcherDraft.text.isEmpty)
        model.recordingIsActive = { false }
        try await launcher.press(36)
        #expect(!model.launcherHistoryMode && model.launcherDraft.text == "Recalled question")
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func emptyHomeFollowsItsSelectionAndSimpleEmptyInputOpensChat() async throws {
        for simple in [false, true] {
            let launcher = try await launch("") { $0.launcherWindowMode = simple ? .simple : .complete }
            defer { launcher.close() }
            let model = launcher.fixture.model
            var opens = 0
            model.onShowConversation = { opens += 1 }
            let action = AskComposer(model: model, launcher: true).launcherPrimaryAction
            #expect(action.mode.symbol == (simple ? "bubble.left" : "return"))
            try await pressButton(in: launcher)
            #expect(opens == (simple ? 1 : 0))
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func duplicateActivationsStillAllowAChangedTargetOrExplicitConfirmation() {
        var gate = AskLauncherActivationGate()
        var target = AskLauncherActivationGate.Target(mode: .execute("Trash"), text: "query",
                                                      selection: "file:a", confirming: false)
        let initial = gate.accept(target, now: 1)
        let duplicate = gate.accept(target, now: 1.1)
        #expect(initial && !duplicate)
        target.confirming = true
        let confirmation = gate.accept(target, now: 1.15)
        let duplicateConfirmation = gate.accept(target, now: 1.2)
        #expect(confirmation && !duplicateConfirmation)
        target.selection = "file:b"
        let nextTarget = gate.accept(target, now: 1.21)
        let later = gate.accept(target, now: 1.5)
        #expect(nextTarget && later)
        for mode in [AskLauncherChatAction.openChat, .askAI, .execute("Open")] {
            #expect(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func toolOnlyInputDoesNotExecuteHomeSuggestionsOrSendAnEmptyMessage() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.skills = ["test-skill"]
        let composer = AskComposer(model: fixture.model, launcher: true)
        #expect(!composer.showsLauncherSuggestions)
        #expect(composer.launcherPrimaryAction.mode == .askAI && !composer.launcherPrimaryAction.enabled)
    }

    @Test func actionStatesRenderInBothAppearances() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, text) in [("execute", "wx"), ("send", "Help me think"), ("chat", ""), ("keyword", "fy hello")] {
                let translation = AskQuickResultsInteractionTests.Translation()
                let launcher = try await launch(text, apps: AskTestAppIndex(AskTestAppIndex.sample.entries)) {
                    $0.launcherWindowMode = .simple
                    if name == "keyword" { translation.install(in: $0) }
                }
                defer { launcher.close() }
                if name == "keyword" {
                    try await launcher.fixture.wait { launcher.fixture.model.plugins.output != nil }
                    #expect(find("ask.launcher.featureWindow", in: launcher.window) != nil)
                }
                launcher.window.appearance = NSAppearance(named: appearance)
                let initialHeight: CGFloat
                switch name {
                case "chat": initialHeight = 76
                case "send": initialHeight = 136
                case "execute": initialHeight = 210
                default: initialHeight = 310
                }
                for _ in 0 ..< 2 {
                    // The first height report may precede the fixture's callback installation.
                    let height = launcher.heights.last ?? initialHeight
                    launcher.window.setContentSize(NSSize(width: AskMetrics.launcherWidth, height: height))
                    try await Task.sleep(for: .milliseconds(100))
                }
                let view = try #require(launcher.window.contentView)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let filename = "gul386-\(name)-\(appearance.rawValue).png"
                let file = URL(fileURLWithPath: path).appendingPathComponent(filename)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }

    private func launch(_ text: String, apps: AskTestAppIndex = AskTestAppIndex([]),
                        prepare: (AskConversationModel) -> Void = { _ in }) async throws -> Launcher {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        return try await Launcher(text: text, apps: apps, prepare: prepare)
    }

    private struct Element {
        var object: NSObject
        func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var frame: NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func find(_ id: String, in window: NSWindow) -> Element? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> Element? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = Element(object: object)
            if element.value("accessibilityIdentifier") as? String == id { return element }
            for child in element.value("accessibilityChildren") as? [Any] ?? [] {
                if let result = walk(child) { return result }
            }
            return nil
        }
        return walk(window)
    }

    private func element(_ id: String, in window: NSWindow) throws -> Element { try #require(find(id, in: window)) }

    private func pressButton(_ id: String = "ask.launcher.openChat", in launcher: Launcher) async throws {
        let button = try element(id, in: launcher.window)
        #expect(button.value("accessibilityEnabled") as? Bool != false)
        let point = launcher.window.convertPoint(fromScreen: NSPoint(x: button.frame.midX, y: button.frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: launcher.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await Task.sleep(for: .milliseconds(60))
    }
}
