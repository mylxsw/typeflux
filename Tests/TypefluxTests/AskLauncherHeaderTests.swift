import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Typeflux

/// The launcher rendered in a real window: captured context stays out of the editor's
/// row, the switches sit in the bottom bar, and recording swaps the results for
/// the voice panel without moving the rest.
@Suite("Ask launcher header", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherHeaderTests {
    private final class Reported { var height: CGFloat = 0 }

    private func host(_ fixture: AskTestFixture, launcher: Bool = true,
                      onDismiss: @escaping () -> Void = {}) -> (NSWindow, Reported) {
        _ = NSApplication.shared
        // SwiftUI builds its accessibility tree only for assistive clients. It is a
        // process-wide flag other suites also set, so it is never switched off here:
        // doing so mid-run would hide their controls from them.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let reported = Reported()
        // Tall enough for a captured selection's home (actions and keyword chips) under the editor.
        let size = NSSize(width: AskMetrics.launcherWidth, height: 480)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = launcher
            ? AnyView(AskLauncherView(model: fixture.model, onDismiss: onDismiss,
                                     onHeightChange: { reported.height = $0 }))
            : AnyView(AskComposer(model: fixture.model, launcher: false, onDismiss: onDismiss))
        let hosting = NSHostingView(rootView: view
            .environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        return (window, reported)
    }

    private func captured(_ fixture: AskTestFixture) {
        var draft = AskDraft()
        draft.source = "Google Chrome — Issues | Multica - Google Chrome"
        draft.sourceBundleID = "com.google.Chrome"
        draft.selection = "first line\nsecond line"
        draft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        fixture.model.launcherDraft = draft
    }

    @Test func enteredFeaturesHideChatControlsAndKeepTheirOwnFooter() async throws {
        let keywords: [(AskKeyword, Bool)] = [
            (AskSystemMonitorPlugin.keywords[0], false),
            (AskSystemInfoPlugin.keywords[0], false),
            (AskEmojiPlugin.keywords[0], true)
        ]
        for (keyword, hasFeatureBar) in keywords {
            let fixture = try AskTestFixture()
            fixture.model.plugins.enter(keyword)
            let (window, _) = host(fixture)
            defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(find("ask.composer.model", in: window) == nil)
            #expect((find("ask.launcher.featureBar", in: window) != nil) == hasFeatureBar)
        }
    }

    @Test func capturedContextLeavesTheEditorClearAndMovesItsSwitchesIntoThePlusMenu() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.token", in: window) == nil)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        let scroll = try #require(editor.enclosingScrollView)
        let editorFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        #expect(editorFrame.minX < window.frame.minX + 40, "the editor starts at the card's left inset")
        // Captured content is no longer a row of chips above the editor.
        #expect(find("ask.content.source.preview", in: window) == nil)
        #expect(find("ask.content.selection.preview", in: window) == nil)
        // The model menu sits in the bottom bar, below the suggestions.
        let model = try element("ask.composer.model", in: window)
        let home = AskLauncherSuggestions.height(for: fixture.model.launcherHome())
        #expect(home > 0)
        #expect(model.frame.maxY < editorFrame.minY - home + 8)
        // Screenshot and memory switch in the "+" menu; only the selected text keeps its chip.
        #expect(find("ask.context.screenshot.toggle", in: window) == nil)
        #expect(find("ask.context.memory.toggle", in: window) == nil)
        #expect(find("ask.context.settings", in: window) == nil)
        let selection = try element("ask.context.selection.toggle", in: window)
        #expect(abs(selection.frame.midY - model.frame.midY) < 2)
        #expect(selection.frame.minX > model.frame.maxX, "the selected text follows the model")
        let footerCenter = window.frame.minY + AskMetrics.launcherGutter + AskComposerChrome.launcher.footerHeight / 2
        #expect(abs(selection.frame.midY - footerCenter) <= 2, "controls stay centred in the taller bottom bar")
        #expect(selection.frame.width == AskMetrics.composerControlHeight)
        let request = fixture.model.launcherDraft.request(deviceId: "device", tools: [])
        #expect(request.source == fixture.model.launcherDraft.source)
        #expect(request.selection == "first line\nsecond line")
        // The expanded launcher keeps one height; the home fills it.
        let expected = AskLauncherWindowMode.expandedHeight
        #expect(abs(reported.height - expected) <= 4, "reported \(reported.height), expected \(expected)")
        let menu = try await openPlusMenu(in: window, fixture: fixture)
        #expect(find("ask.add.selection", in: menu) != nil)
        #expect(find("ask.add.screenshot", in: menu) != nil)
        try press(try element("ask.add.memory", in: menu))
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == true }
        try await fixture.wait {
            find("ask.add.memory", in: menu)?.value("accessibilityValue") as? String
                == L("ask.context.selection.disabled")
        }
        try press(try element("ask.add.memory", in: menu))
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == nil }
        AskGlassMenuPresenter.shared.hide()
    }

    @Test func plusMenuSwitchesTheScreenshot() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 320, height: 200), type: .png)
        fixture.model.launcherDraft.screenshot = "data:image/png;base64," + png.base64EncodedString()
        fixture.model.launcherDraft.capturedAt = Date()
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession(); AskGlassMenuPresenter.shared.hide() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.model.launcherDraft.includeScreenshot)
        let menu = try await openPlusMenu(in: window, fixture: fixture)
        // The thumbnail beside the switch is covered by `AskComposerAddMenuTests`; this host
        // does not present captured images (the old hover preview test could not either).
        try press(try element("ask.add.screenshot", in: menu))
        try await fixture.wait { !fixture.model.launcherDraft.includeScreenshot }
        #expect(fixture.model.launcherDraft.screenshot != nil, "the captured image can still be restored")
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).image == nil)
        #expect(AskGlassMenuPresenter.shared.isShowing, "a switch keeps the menu open for the next one")
        try press(try element("ask.add.screenshot", in: menu))
        try await fixture.wait { fixture.model.launcherDraft.includeScreenshot }
    }

    @Test func `selection chip stays on the bar and toggles the outgoing text`() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        fixture.model.launcherDraft.selection = "In May, we merged around 2,500 code changes per day. "
            + "In September, we merged more than 30,000 per day. As a result, we became "
            + "bottlenecked by developer infrastructure built for human (rather than agent) scale."
        fixture.model.launcherDraft.text = "请帮我分析这段内容"
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let original = fixture.model.launcherDraft
        let selection = try element("ask.context.selection.toggle", in: window)
        let model = try element("ask.composer.model", in: window)
        #expect(abs(selection.frame.midY - model.frame.midY) < 2)
        try saveSnapshot(#require(window.contentView), name: "selection-toggle-enabled")
        try hover(selection, in: window, inside: true)
        let card = try await hoverCard(in: window, fixture: fixture)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!card.canBecomeKey && !card.canBecomeMain)
        #expect(!card.ignoresMouseEvents, "the text can be scrolled without taking editor focus")
        #expect(find("ask.context.selection.hoverText", in: card) != nil)
        try saveSnapshot(#require(card.contentView), name: "selection-hover-enabled")
        // Clicking after the hover opened must toggle on the first click.
        try click(selection, in: window)
        try await fixture.wait { fixture.model.launcherDraft.selectionOff == true }
        #expect(!card.isVisible)
        let off = fixture.model.launcherDraft
        #expect(off.selection == original.selection && off.text == original.text)
        #expect(off.source == original.source && off.memory == original.memory)
        #expect(off.request(deviceId: "device", tools: []).selection == nil)
        let disabled = try element("ask.context.selection.toggle", in: window)
        try await fixture.wait {
            find("ask.context.selection.toggle", in: window)?.value("accessibilityValue") as? String
                == L("ask.context.selection.disabled")
        }
        try saveSnapshot(#require(window.contentView), name: "selection-toggle-disabled")
        try hover(disabled, in: window, inside: true)
        let disabledCard = try await hoverCard(in: window, fixture: fixture)
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.selection.hoverText", in: disabledCard) != nil,
                "disabled text remains inspectable")
        try saveSnapshot(#require(disabledCard.contentView), name: "selection-hover-disabled")
        try click(disabled, in: window)
        try await fixture.wait { fixture.model.launcherDraft.selectionOff == nil }
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).selection == original.selection)
    }

    @Test func `launcher without captured text has no selection switch`() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        fixture.model.launcherDraft.selection = nil
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.selection.toggle", in: window) == nil)
        #expect(find("ask.context.memory.toggle", in: window) == nil)
        let menu = try await openPlusMenu(in: window, fixture: fixture)
        #expect(find("ask.add.selection", in: menu) == nil)
        #expect(find("ask.add.memory", in: menu) != nil)
        AskGlassMenuPresenter.shared.hide()
    }

    @Test func headerSendsTheQuestionInsteadOfTransferringAnUnsentDraft() async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft.text = "Help me think"
        var opens = 0
        fixture.model.onShowConversation = { opens += 1 }
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let button = try element("ask.launcher.openChat", in: window)
        let voice = try element("ask.composer.voice", in: window)
        let model = try element("ask.composer.model", in: window)
        #expect(find("ask.composer.send", in: window) == nil)
        #expect(abs(button.frame.midY - voice.frame.midY) < 2)
        #expect(button.frame.minX > voice.frame.maxX)
        #expect(button.frame.minY > model.frame.maxY)
        #expect(button.frame.width == AskSendButton.size)
        #expect(button.value("accessibilityLabel") as? String == L("ask.quick.askAI"))
        try click(button, in: window)
        try await fixture.wait { opens == 1 }
        #expect(fixture.model.launcherDraft.text.isEmpty)
        for _ in 0 ..< 100 where await fixture.api.sends.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await fixture.api.sends.count == 1)
        #expect(await fixture.api.sends.first?.text == "Help me think")
    }

    @Test func emptyHeaderOpensChatAndTypingChangesTheSameButton() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        fixture.model.launcherWindowMode = .simple
        fixture.model.draft.text = "Existing draft"
        var opens = 0
        fixture.model.onShowConversation = { opens += 1 }
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(200))
        let button = try element("ask.launcher.openChat", in: window)
        #expect(button.value("accessibilityLabel") as? String == L("ask.openChat"))
        try click(button, in: window)
        try await fixture.wait { opens == 1 }
        #expect(fixture.model.draft.text == "Existing draft")
        #expect(await fixture.api.sends.isEmpty)

        fixture.model.launcherDraft.text = "New question"
        try await Task.sleep(for: .milliseconds(100))
        #expect(try element("ask.launcher.openChat", in: window).value("accessibilityLabel") as? String == L("ask.quick.askAI"))
        fixture.model.launcherDraft.text = " \n "
        try await Task.sleep(for: .milliseconds(100))
        #expect(try element("ask.launcher.openChat", in: window).value("accessibilityLabel") as? String == L("ask.openChat"))
    }

    @Test(arguments: [false, true])
    func commandOOpensChatWithAnUnsentDraftAndKeepsItOnAnEmptyOpen(attachmentOnly: Bool) async throws {
        let fixture = try AskTestFixture()
        let incoming = attachmentOnly
            ? AskDraft(includeScreenshot: false, attachments: [AskAttachment(kind: .file, name: "notes.txt", text: "Notes")])
            : AskDraft(text: "Unsent question", includeScreenshot: false)
        fixture.model.launcherDraft = incoming
        var opens = 0
        fixture.model.onShowConversation = { opens += 1 }
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        let event = try key("o", code: 31, modifiers: .command, in: window)
        editor.keyDown(with: event)
        try await fixture.wait { opens == 1 }
        #expect(fixture.model.draft == incoming)
        #expect(!fixture.model.launcherDraft.hasChatInput)
        #expect(await fixture.api.sends.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        editor.keyDown(with: event)
        try await fixture.wait { opens == 2 }
        #expect(fixture.model.draft == incoming)
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func attachmentOnlyHeaderSendsAndNeverFallsBackToOpeningWhileBusy() async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft = AskDraft(includeScreenshot: false)
        let loadingKey = fixture.model.visionDraftKey(launcher: true)
        fixture.model.attachmentLoads[loadingKey] = 1
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(200))
        let disabled = try element("ask.launcher.openChat", in: window)
        #expect(disabled.value("accessibilityLabel") as? String == L("ask.quick.askAI"))
        #expect(disabled.value("isAccessibilityEnabled") as? Bool == false)
        fixture.model.launcherDraft.attachments = [AskAttachment(kind: .file, name: "notes.txt", text: "Notes")]
        fixture.model.attachmentLoads[loadingKey] = nil
        try await Task.sleep(for: .milliseconds(100))
        try click(try element("ask.launcher.openChat", in: window), in: window)
        for _ in 0 ..< 100 where await fixture.api.sends.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await fixture.api.sends.count == 1)
        #expect(await fixture.api.sends.first?.attachments?.first?.name == "notes.txt")
    }

    @Test(arguments: [true, false])
    func warningCanBeClosedWithoutChangingTheDraftAndNewFailuresReappear(voiceWarning: Bool) async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft.text = "Keep this draft"
        if voiceWarning { fixture.model.voiceInput.error = "Sign in to use cloud models" }
        else { fixture.model.error = "Request failed" }
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let before = reported.height
        let kind = voiceWarning ? "voice" : "sendError"
        #expect(find("ask.notice.\(kind)", in: window) != nil)
        try saveSnapshot(window.contentView!, name: "warning-\(kind)-before-close")
        try click(try element("ask.banner.dismiss", in: window), in: window)
        try await fixture.wait {
            voiceWarning ? fixture.model.voiceInput.error == nil : fixture.model.error == nil
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(find("ask.notice.\(kind)", in: window) == nil)
        try saveSnapshot(window.contentView!, name: "warning-\(kind)-after-close")
        #expect(reported.height < before)
        #expect(fixture.model.launcherDraft.text == "Keep this draft")
        #expect(await fixture.api.sends.isEmpty)
        if voiceWarning { fixture.model.voiceInput.error = "Sign in to use cloud models" }
        else { fixture.model.error = "Request failed" }
        try await Task.sleep(for: .milliseconds(200))
        #expect(find("ask.notice.\(kind)", in: window) != nil)
        #expect(find("ask.banner.dismiss", in: window) != nil)
    }

    @Test func workspaceKeepsItsSendButton() async throws {
        let fixture = try AskTestFixture()
        fixture.model.draft.text = "Follow up"
        let (window, _) = host(fixture, launcher: false)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.composer.send", in: window) != nil)
        #expect(find("ask.launcher.openChat", in: window) == nil)
    }

    @Test func recordingSwapsTheResultsForTheVoicePanel() async throws {
        let fixture = try AskTestFixture()
        fixture.model.appIndex = AskTestAppIndex(AskTestAppIndex.sample.entries)
        captured(fixture)
        let recorder = AskTestVoiceRecorder()
        recorder.holdTranscript = true
        fixture.model.voiceInput.recorder = recorder
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let resting = reported.height
        #expect(AskVoicePanel.minimumHeight <= AskLauncherSuggestions.height(for: fixture.model.launcherHome()))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        #expect(fixture.model.voiceInput.begin(in: editor))
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.voice.panel", in: window) != nil)
        #expect(find("ask.voice.cancel", in: window) != nil)
        #expect(find("ask.context.token", in: window) == nil)
        #expect(find("ask.composer.send", in: window) == nil)
        #expect(find("ask.launcher.openChat", in: window) == nil)
        #expect(find("ask.composer.model", in: window) != nil, "the bottom bar stays")
        // The panel takes the suggestions' height, so the launcher does not move.
        #expect(abs(reported.height - resting) <= 1, "recording \(reported.height), resting \(resting)")
        fixture.model.voiceInput.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.voice.panel", in: window) == nil)
        #expect(find("ask.launcher.openChat", in: window) != nil)
        #expect(find("ask.context.token", in: window) == nil)
        #expect(find("ask.context.settings", in: window) == nil)
        #expect(find("ask.context.selection.toggle", in: window) != nil, "the selected text keeps its chip")
    }

    @Test func voicePanelFillsTheResultsAreaWithoutResizingTheLauncher() async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft.text = "a question with no quick results"
        let recorder = AskTestVoiceRecorder()
        recorder.holdTranscript = true
        fixture.model.voiceInput.recorder = recorder
        let (window, reported) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        // A loaded Mac can finish the quick search after a fixed wait; measure only at rest.
        let resting = try await settledHeight(fixture, reported)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        #expect(fixture.model.voiceInput.begin(in: editor))
        #expect(abs(try await settledHeight(fixture, reported) - resting) <= 1,
                "recording takes the results' place at the launcher's one height")
        let chrome = AskMetrics.launcherHeight(editor: 32, banners: 0)
        #expect(resting - chrome >= AskVoicePanel.minimumHeight, "the results area holds the whole voice panel")
        fixture.model.voiceInput.cancel()
        #expect(abs(try await settledHeight(fixture, reported) - resting) <= 1)
    }

    /// The launcher's reported height once its quick search has finished and layout is still.
    private func settledHeight(_ fixture: AskTestFixture, _ reported: Reported) async throws -> CGFloat {
        var last = reported.height
        var stableSamples = 0
        for _ in 0 ..< 250 where stableSamples < 5 {
            try await Task.sleep(for: .milliseconds(20))
            let height = reported.height
            stableSamples = !fixture.model.quickSearch.isSearching && height == last ? stableSamples + 1 : 0
            last = height
        }
        #expect(stableSamples >= 5, "The launcher height never settled")
        return last
    }

    @Test func commandKOpensAndClosesContextSettingsWithoutAnExtraFooterButton() async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(find("ask.context.settings", in: window) == nil)
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(editor.performKeyEquivalent(with: event))
        try await fixture.wait { NSApp.windows.contains { $0.isVisible && find("ask.context.panel", in: $0) != nil } }
        #expect(editor.performKeyEquivalent(with: event))
        try await fixture.wait { !NSApp.windows.contains { $0.isVisible && find("ask.context.panel", in: $0) != nil } }
    }

    @Test(arguments: AskLauncherWindowMode.allCases)
    func escapeClosesTheContextPanelBeforeTheLauncher(_ mode: AskLauncherWindowMode) async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherWindowMode = mode
        captured(fixture)
        var dismissed = 0
        let (window, _) = host(fixture, onDismiss: { dismissed += 1 })
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeFirstResponder(editor)
        #expect(editor.performKeyEquivalent(with: try key("k", code: 40, modifiers: .command, in: window)))
        let panel = { NSApp.windows.first { $0.isVisible && find("ask.context.panel", in: $0) != nil } }
        try await fixture.wait { panel() != nil }
        // The same glass card as the composer's other menus, never key, so the launcher keeps typing.
        let card = try #require(panel())
        #expect(card is AskGlassMenuPresenter.Panel && !card.canBecomeKey)
        #expect(window.firstResponder === editor)
        editor.keyDown(with: try key("\u{1b}", code: 53, in: window))
        try await fixture.wait { panel() == nil }
        #expect(dismissed == 0, "the first Esc closes only the panel")
        editor.keyDown(with: try key("\u{1b}", code: 53, in: window))
        #expect(dismissed == 1)
    }

    @Test(arguments: ["/", "、"])
    func slashTokensSendAsOrdinaryLauncherText(_ separator: String) async throws {
        let fixture = try AskTestFixture()
        captured(fixture)
        let (window, _) = host(fixture)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editor.keyDown(with: try key(separator, code: 44, in: window))
        editor.insertText("memory", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(200))
        let text = separator + "memory"
        #expect(fixture.model.launcherDraft.text == text)
        #expect(find("ask.command.palette", in: window) == nil)
        #expect(fixture.model.launcherDraft.memoryOff == nil)
        editor.keyDown(with: try key("\r", code: 36, in: window))
        try await fixture.wait { fixture.model.selected?.messages.contains { $0.role == "assistant" } == true }
        let sent = try #require(await fixture.api.sends.first)
        #expect(sent.text == text, "a former command is sent as the user's question")
        #expect(fixture.model.commandFeedback == nil)
    }

    @Test func launcherCommandSlashDoesNotEditTheDraftAndEscapeStillDismisses() async throws {
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft.text = "an ordinary question"
        var dismissed = false
        let (window, _) = host(fixture, onDismiss: { dismissed = true })
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        #expect(!window.performKeyEquivalent(with: try key("/", code: 44, modifiers: .command, in: window)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.model.launcherDraft.text == "an ordinary question")
        #expect(find("ask.command.palette", in: window) == nil)
        editor.keyDown(with: try key("\u{1b}", code: 53, in: window))
        #expect(dismissed)
    }

    @Test func workspaceStillOpensAndExecutesSlashCommands() async throws {
        let fixture = try AskTestFixture()
        fixture.model.draft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        let (window, _) = host(fixture, launcher: false)
        defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(descendants(window.contentView!).compactMap { $0 as? AskComposerTextView.Editor }.first)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        // Let each edit render, like the existing command keyboard tests.
        for character in "/memory" {
            editor.keyDown(with: try key(String(character), code: character == "/" ? 44 : 0, in: window))
            try await Task.sleep(for: .milliseconds(120))
        }
        try await fixture.wait { find("ask.command.palette", in: window) != nil }
        editor.keyDown(with: try key("\r", code: 36, in: window))
        try await fixture.wait { fixture.model.draft.memoryOff == true }
        #expect(fixture.model.draft.text.isEmpty)
        #expect(find("ask.command.palette", in: window) == nil)
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func everyLauncherLocalizationOmitsTheCommandHint() {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            #expect(!L("ask.launcher.placeholder").contains("/"))
            #expect(L("ask.input.placeholder").contains("/"))
            #expect(L("ask.followup.placeholder").contains("/"))
        }
    }

    /// Presses a row in the glass menu. The panel never becomes key, so the rows are pressed
    /// through accessibility rather than with synthetic clicks.
    private func press(_ element: Element) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try #require(element.object.responds(to: selector), "The row can be pressed")
        _ = element.object.perform(selector)
    }

    /// Clicks "+" and returns the glass panel its menu opens in.
    private func openPlusMenu(in window: NSWindow, fixture: AskTestFixture) async throws -> NSWindow {
        try click(try element("ask.composer.attach", in: window), in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let panel = try #require(AskGlassMenuPresenter.shared.panel)
        try await fixture.wait { find("ask.add.menu", in: panel) != nil }
        return panel
    }

    private func hoverCard(in window: NSWindow, fixture: AskTestFixture,
                           phase: String = "hover") async throws -> NSWindow {
        // Observe the rendered panel rather than assuming its asynchronous layout finished after 300 ms.
        try await fixture.wait {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.childWindows?.contains { $0 is AskHoverCardPresenter.Panel && $0.isVisible } == true
        }
        let children = window.childWindows?.map {
            "\(type(of: $0)) visible=\($0.isVisible) frame=\($0.frame)"
        }.joined(separator: "; ") ?? "none"
        let state = "\(phase): parentVisible=\(window.isVisible), children=\(children), "
            + "includeScreenshot=\(fixture.model.launcherDraft.includeScreenshot), "
            + "hasCapture=\(fixture.model.launcherDraft.screenshot != nil)"
        return try #require(window.childWindows?.first { $0 is AskHoverCardPresenter.Panel && $0.isVisible }, "\(state)")
    }

    private func saveSnapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("gul235-\(name).png"))
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func click(_ element: Element, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func hover(_ element: Element, in window: NSWindow, inside: Bool) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        var delivered = false
        for view in descendants(try #require(window.contentView)) {
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: nil)) else { continue }
                guard let owner = area.owner as? NSResponder else { continue }
                let event = HeaderHoverEvent(area: area, point: point, window: window, inside: inside)
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
                delivered = true
            }
        }
        #expect(delivered, "the screenshot button has a native hover tracking area")
    }

    // MARK: - Accessibility lookup

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// SwiftUI's accessibility nodes expose the Objective-C selectors but do
    /// not conform to NSAccessibilityProtocol. KVC boxes their NSRect safely.
    private struct Element {
        let object: NSObject
        func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var children: [Any] { value("accessibilityChildren") as? [Any] ?? [] }
        var frame: NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func find(_ value: String, attribute: String = "accessibilityIdentifier", in window: NSWindow) -> Element? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> Element? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = Element(object: object)
            if element.value(attribute) as? String == value { return element }
            for child in element.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> Element {
        try #require(find(identifier, in: window), "Missing accessibility element: \(identifier)")
    }
}

/// SwiftUI routes an enter/exit event through its tracking area. The event factory
/// leaves that area nil; supply it explicitly without moving the user's pointer.
private final class HeaderHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int
    private let eventType: NSEvent.EventType

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow, inside: Bool) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        eventType = inside ? .mouseEntered : .mouseExited
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { targetWindowNumber }
    override var type: NSEvent.EventType { eventType }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
