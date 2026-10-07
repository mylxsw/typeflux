import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Open chat from launcher", .serialized)
@MainActor
struct AskOpenChatTests {
    @Test func emptyOpenKeepsCurrentConversationAndIgnoresCapturedContext() async throws {
        let f = try AskTestFixture()
        await f.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.draft.text = "Existing draft"
        f.model.launcherDraft = AskDraft(text: "chat", selection: "Automatic selection", source: "Safari")
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        #expect(await f.model.openChatFromLauncher())
        #expect(opens == 1)
        #expect(f.model.selectedId == "old")
        #expect(f.model.draft.text == "Existing draft")
        #expect(f.model.draft.selection == nil)
        #expect(f.model.launcherDraft.text.isEmpty)
        #expect(await f.api.sends.isEmpty)
    }

    @Test func argumentTransfersWithoutSendingAndPersistsOldConversationDraft() async throws {
        let f = try AskTestFixture()
        await f.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.draft.text = "Keep this"
        f.model.launcherDraft = AskDraft(text: "chat Help me think", includeScreenshot: false,
                                         selection: "Context", source: "Notes", modelRef: "custom:test",
                                         storesLocally: true)
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.selectedId == nil)
        #expect(f.model.draft.text == "Help me think")
        #expect(f.model.draft.selection == "Context")
        #expect(f.model.draft.modelRef == "custom:test")
        #expect(f.model.draft.storesLocally == true)
        #expect(f.model.launcherDraft.text.isEmpty)
        #expect(try await f.cache.draft(key: "old", owner: "owner")?.text == "Keep this")
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
        #expect(f.model.conversations.count == 0)
        await f.model.select("old")
        #expect(f.model.draft.text == "Keep this")
    }

    @Test func displacedNewDraftIsDurableAndCanBeSwappedBack() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        f.model.draft = AskDraft(text: "Original unsent", storesLocally: true)
        f.model.launcherDraft.text = "Incoming"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.text == "Incoming")
        let saved = try #require(f.model.savedChatDrafts.first)
        #expect(saved.draft.text == "Original unsent")
        let reopened = try AskConversationCache(url: f.root.appendingPathComponent("cache.sqlite"))
        #expect(try await reopened.savedChatDrafts(owner: "owner").first?.draft.storesLocally == true)
        #expect(try await reopened.savedChatDrafts(owner: "other").isEmpty)
        await f.model.restoreChatDraft(saved)
        #expect(f.model.draft.text == "Original unsent")
        #expect(f.model.savedChatDrafts.first?.draft.text == "Incoming")
        #expect(try await f.cache.list(owner: "owner").isEmpty)
        f.model.resetSession()
        #expect(f.model.savedChatDrafts.isEmpty)
    }

    @Test func activeChatUsesOnlyArgumentAndOtherPluginsKeepTheirInput() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        f.model.plugins.enter(AskOpenChatPlugin.keywords[0])
        f.model.launcherDraft.text = "Argument only"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.text == "Argument only")
        #expect(!f.model.plugins.isActive)
        let translation = AskTranslatePlugin.keywords[0]
        f.model.plugins.enter(translation)
        f.model.launcherDraft.text = "Translate me"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.text == "Argument only")
        #expect(f.model.plugins.keyword == translation)
        #expect(f.model.launcherDraft.text == "Translate me")
        f.model.foldLauncherKeyword()
        #expect(f.model.launcherDraft.text == translation.keyword + " Translate me")
    }

    @Test func renamedAndDisabledKeywordsFollowSettingsAndBoundaries() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let renamed = AskKeyword(keyword: "talk", pluginID: AskOpenChatPlugin.id)
        f.model.modelLibrary.settings.saveAskLauncherKeywords([renamed])
        #expect(AskKeywordMatcher.match("chat", keywords: f.model.launcherKeywords) == nil)
        #expect(AskKeywordMatcher.match("talkative", keywords: f.model.launcherKeywords) == nil)
        #expect(AskKeywordMatcher.match("/talk", keywords: f.model.launcherKeywords) == nil)
        #expect(AskKeywordMatcher.match("body talk", keywords: f.model.launcherKeywords) == nil)
        f.model.launcherDraft.text = "talk: body"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.text == "body")
        var disabled = renamed
        disabled.enabled = false
        f.model.modelLibrary.settings.saveAskLauncherKeywords([disabled])
        f.model.launcherDraft.text = "talk body"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.text == "talk body")
        #expect(AskPluginRegistry.keywords(saved: [], known: AskPluginRegistry.coveredGroups).isEmpty)
        #expect(AskPluginRegistry.keywords(saved: [], known: [AskTranslatePlugin.id]).contains(AskOpenChatPlugin.keywords[0]))
    }

    @Test func openingWaitsForRecordingCaptureAndAttachmentLoads() async throws {
        let f = try AskTestFixture()
        f.model.launcherDraft.text = "Do not lose me"
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        f.model.recordingIsActive = { true }
        #expect(!(await f.model.openChatFromLauncher()))
        f.model.recordingIsActive = { false }
        for launcher in [true, false] {
            let key = f.model.visionDraftKey(launcher: launcher)
            f.model.attachmentLoads[key] = 1
            #expect(!(await f.model.openChatFromLauncher()))
            f.model.attachmentLoads[key] = nil
        }
        f.model.isOpeningChat = true
        #expect(!(await f.model.openChatFromLauncher()))
        #expect(opens == 0)
        #expect(f.model.launcherDraft.text == "Do not lose me")
    }

    @Test func manualReferencesCountButAutomaticContextDoesNot() {
        #expect(!AskDraft(selection: "Selected", source: "Safari").hasChatInput)
        #expect(!AskDraft(text: " \n ").hasChatInput)
        #expect(AskDraft(text: "text").hasChatInput)
        #expect(AskDraft(skills: ["skill"]).hasChatInput)
        #expect(AskDraft(mcpServers: ["server"]).hasChatInput)
    }

    @Test func pluginPlanIsAnExplicitLocalActionEvenForEmptyOrSelectedInput() async throws {
        let plugin = AskOpenChatPlugin()
        #expect(plugin.runsWithoutInput)
        #expect(plugin.id == AskKeywordKind.chat.pluginID)
        #expect(!plugin.title.isEmpty && !plugin.placeholder(selectionLines: 2).isEmpty)
        #expect(plugin.chipDetail(for: plugin.defaultKeywords[0], language: .english) == nil)
        let request = AskPluginRequest(text: "Selected text", origin: .selection,
                                        keyword: plugin.defaultKeywords[0], options: [:], interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        #expect(plan.mode == .onSubmit)
        #expect(plan.action(for: .enter)?.kind == .openChat)
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
        do {
            _ = try await plugin.run(request, plan: plan, progress: { _ in })
            Issue.record("An open-chat action must never run inference")
        } catch is CancellationError {} catch { Issue.record(error) }
        var editor = AskKeywordDraft(editing: plugin.defaultKeywords[0])
        editor.keyword = "talk"
        #expect(editor.fieldProblem == nil && editor.titlePlaceholder.isEmpty)
        #expect(editor.displayName == plugin.title)
        #expect(editor.result().keyword == "talk")
    }

    @Test func nativeShortcutHandlesCommandOAndDefersDuringIMEComposition() throws {
        let editor = AskComposerTextView.Editor()
        var opens = 0
        editor.onOpenChat = { opens += 1 }
        func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: "o",
                                          charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
        }
        let commandO = try event(.command)
        editor.keyDown(with: commandO)
        #expect(opens == 1)
        #expect(!AskComposerTextView.Editor.isOpenChatShortcut(try event([.command, .shift])))
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: commandO)
        #expect(opens == 1)
    }
}

extension AskOpenChatTests {
    @Test func cacheFailureLeavesBothDraftsAndLauncherIntact() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        f.model.draft.text = "Original"
        f.model.launcherDraft.text = "Incoming"
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        try await f.cache.execute("CREATE TRIGGER fail_drafts BEFORE INSERT ON ask_drafts BEGIN SELECT RAISE(ABORT, 'unavailable'); END", strings: [])
        #expect(!(await f.model.openChatFromLauncher()))
        #expect(f.model.draft.text == "Original")
        #expect(f.model.launcherDraft.text == "Incoming")
        #expect(opens == 0)
        #expect(!f.model.isOpeningChat)
        #expect(f.model.commandFeedback == L("ask.cache.failed"))
    }

    @Test func simultaneousRequestsDoNotReplaceTheTransferredDraft() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        f.model.draft.text = "Original"
        f.model.launcherDraft.text = "Incoming"
        async let first = f.model.openChatFromLauncher()
        async let second = f.model.openChatFromLauncher()
        let results = await [first, second]
        #expect(results.contains(true))
        #expect(f.model.draft.text == "Incoming")
        #expect(f.model.savedChatDrafts.filter { $0.draft.text == "Original" }.count == 1)
        #expect(await f.api.sends.isEmpty)
    }

    @Test func quoteOnlyDraftTransfersAndSavedCopyRestoresIntoEmptyWorkspace() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let quote = AskReference(messageId: "message", text: "A quote")
        f.model.draft.text = "Old unsent"
        f.model.launcherDraft = AskDraft(references: [quote])
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.references == [quote])
        let saved = try #require(f.model.savedChatDrafts.first)
        f.model.newConversation()
        await f.model.restoreChatDraft(saved)
        #expect(f.model.draft.text == "Old unsent")
        #expect(f.model.savedChatDrafts.isEmpty)
    }
}

extension AskOpenChatTests {
    @Test func launcherReturnAndCommandOOpenWithoutSending() async throws {
        _ = NSApplication.shared
        for (text, command, expected) in [("chat", false, ""), ("chat Draft words", false, "Draft words"), ("", true, "")] {
            let f = try AskTestFixture()
            _ = f.model.credentials()
            f.model.quickSearch.setVisible(true)
            f.model.launcherDraft.text = text
            var opens = 0
            f.model.onShowConversation = { opens += 1 }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AskLauncherView(model: f.model, onDismiss: {}))
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer { window.close(); f.model.resetSession() }
            try await Task.sleep(for: .milliseconds(200))
            func find(_ view: NSView) -> AskComposerTextView.Editor? {
                (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(find).first
            }
            if text == "chat", let directory = ProcessInfo.processInfo.environment["TYPEFLUX_OPEN_CHAT_SNAPSHOT"] {
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("open-chat.png"))
            }
            let editor = try #require(find(hosting))
            window.makeFirstResponder(editor)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                      modifierFlags: command ? .command : [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: command ? "o" : "\r",
                                                      charactersIgnoringModifiers: command ? "o" : "\r",
                                                      isARepeat: false, keyCode: command ? 31 : 36))
            if command { #expect(editor.performKeyEquivalent(with: event)) } else { editor.keyDown(with: event) }
            try await f.wait { opens == 1 }
            #expect(f.model.draft.text == expected)
            #expect(await f.api.sends.isEmpty)
            #expect(await f.localAPI.sends.isEmpty)
        }
    }

    @Test func windowReusesAndRestoresMinimizedConversationWithEditorFocus() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let controller = AskConversationWindowController(settings: f.model.modelLibrary.settings, model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }
        #expect(await f.model.openChatFromLauncher())
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-conversations" && $0.isVisible })
        defer { window.close() }
        window.miniaturize(nil)
        #expect(await f.model.openChatFromLauncher())
        #expect(!window.isMiniaturized)
        #expect(window.isVisible)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder is AskComposerTextView.Editor)
        #expect(NSApp.windows.filter { $0.identifier == window.identifier && $0.isVisible }.count == 1)
    }
}

@MainActor
private final class OpenChatHeldCapture: AskContextCapturing {
    var continuation: CheckedContinuation<AskCapturedContext, Never>?
    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
        await withCheckedContinuation { continuation = $0 }
    }
}

extension AskOpenChatTests {
    @Test func captureMustFinishBeforeDraftHandoff() async throws {
        let f = try AskTestFixture()
        let capture = OpenChatHeldCapture()
        let model = AskConversationModel(api: f.api, cache: f.cache, tools: f.tools, capture: capture,
                                         deviceId: "test", modelLibrary: f.model.modelLibrary,
                                         session: { ("owner", "token") })
        let task = Task { await model.prepareLauncher() }
        try await f.wait { capture.continuation != nil }
        #expect(model.capturing)
        #expect(!(await model.openChatFromLauncher()))
        capture.continuation?.resume(returning: .init(selection: "Automatic context"))
        await task.value
        #expect(await model.openChatFromLauncher())
        #expect(model.draft.selection == nil)
    }

    @Test func recordingAndTranscriptionKeepTheirEditorAndContent() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let recorder = AskTestVoiceRecorder()
        recorder.holdTranscript = true
        f.model.voiceInput.recorder = recorder
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.voice = f.model.voiceInput
        let window = AskTestVoiceWindow(contentRect: editor.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        defer { window.close(); f.model.resetSession() }
        #expect(f.model.voiceInput.begin(in: editor))
        try await f.wait { f.model.voiceInput.phase == .listening }
        #expect(!(await f.model.openChatFromLauncher()))
        f.model.voiceInput.stop()
        try await f.wait { recorder.stops == 1 }
        #expect(!(await f.model.openChatFromLauncher()))
        #expect(recorder.cancels == 0)
        recorder.releaseTranscript()
        try await f.wait { !f.model.voiceInput.isOccupied }
        #expect(editor.string == recorder.transcript)
    }
}

extension AskOpenChatTests {
    @Test func attachmentOnlyDraftCarriesAllContextWithoutSending() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let attachment = AskAttachment(kind: .file, name: "notes.txt", text: "Notes")
        f.model.launcherDraft = AskDraft(includeScreenshot: false, screenshot: "captured image",
                                         selection: "Selection", source: "Editor", sourceBundleID: "test.editor",
                                         sourceOff: true, capturedAt: Date(), modelRef: "cloud:default",
                                         selectionOff: true, attachments: [attachment], storesLocally: false)
        let incoming = f.model.launcherDraft
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft == incoming)
        #expect(f.model.launcherDraft.attachments == nil)
        #expect(await f.api.sends.isEmpty)
    }

    @Test func pluginActionOpensAndRawPluginInputIsPreservedBeforeDetection() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        f.model.launcherDraft.text = "fy translate this"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.launcherDraft.text == "fy translate this")
        #expect(f.model.draft.text.isEmpty)
        f.model.launcherDraft.text = "chat"
        #expect(f.model.performPluginAction(.init(kind: .openChat, title: "Open", symbol: "macwindow")) == .stay)
        try await f.wait { opens == 2 }
        #expect(f.model.launcherDraft.text.isEmpty)
        #expect(await f.api.sends.isEmpty)
    }
}

extension AskOpenChatTests {
    @Test func restoringFromConversationPreservesFollowUpAndRejectsStaleAccountEntry() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let saved = AskSavedChatDraft(id: "saved-chat:test", draft: AskDraft(text: "Restore me"))
        try await f.cache.saveDraft(saved.draft, key: saved.id, owner: "owner")
        await f.model.loadSavedChatDrafts()
        await f.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.draft.text = "Follow-up"
        await f.model.restoreChatDraft(saved)
        #expect(f.model.selectedId == nil)
        #expect(f.model.draft.text == "Restore me")
        #expect(try await f.cache.draft(key: "old", owner: "owner")?.text == "Follow-up")
        #expect(f.model.savedChatDrafts.isEmpty)
        f.model.resetSession()
        await f.model.restoreChatDraft(saved)
        #expect(f.model.draft.text.isEmpty)
    }

    @Test func restoreFailureKeepsVisibleAndSavedDrafts() async throws {
        let f = try AskTestFixture()
        _ = f.model.credentials()
        let saved = AskSavedChatDraft(id: "saved-chat:test", draft: AskDraft(text: "Saved"))
        try await f.cache.saveDraft(saved.draft, key: saved.id, owner: "owner")
        await f.model.loadSavedChatDrafts()
        f.model.draft.text = "Visible"
        try await f.cache.execute("CREATE TRIGGER fail_drafts BEFORE INSERT ON ask_drafts BEGIN SELECT RAISE(ABORT, 'unavailable'); END", strings: [])
        await f.model.restoreChatDraft(saved)
        #expect(f.model.draft.text == "Visible")
        #expect(f.model.savedChatDrafts == [saved])
        #expect(!f.model.isOpeningChat)
    }
}
