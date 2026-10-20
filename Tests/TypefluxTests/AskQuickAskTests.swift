import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskQuickAskTests {
    private func prepare(_ f: AskTestFixture, text: String = "Explain actors") {
        _ = f.model.credentials()
        f.model.plugins.enter(AskQuickAskPlugin.keywords[0])
        f.model.launcherDraft = AskDraft(text: text, includeScreenshot: false)
    }

    private func answer(_ f: AskTestFixture) async throws {
        f.model.submitQuickAsk()
        try await f.wait { f.model.quickAsk?.persisted == true && !f.model.quickAskRunning }
        #expect(f.model.quickAskAnswer == "This is the answer.")
    }

    @Test func keywordIsExplicitConfigurableAndDoesNotStealWorkflows() async throws {
        let plugin = AskQuickAskPlugin()
        #expect(plugin.entersOnReturn && !plugin.usesSelectionInput && !plugin.runsWithoutInput)
        #expect(plugin.defaultKeywords == AskQuickAskPlugin.keywords)
        #expect(!plugin.title.isEmpty && !plugin.placeholder(selectionLines: nil).isEmpty)
        #expect(plugin.chipDetail(for: AskQuickAskPlugin.keywords[0], language: .english) == nil)
        let request = AskPluginRequest(text: "hello", origin: .argument, keyword: AskQuickAskPlugin.keywords[0],
                                       options: [:], interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        #expect(plan.mode == .onSubmit)
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
        do { _ = try await plugin.run(request, plan: plan) { _ in }; Issue.record("Plugin must not send") }
        catch is CancellationError {} catch { Issue.record(error) }
        #expect(AskKeywordMatcher.match("qa Question", keywords: AskPluginRegistry.defaultKeywords) != nil)
        #expect(AskKeywordMatcher.match("quality", keywords: AskPluginRegistry.defaultKeywords) == nil)
        let occupied = AskPluginRegistry.keywords(saved: nil, known: nil, reserved: ["qa"])
        #expect(!occupied.contains { $0.pluginID == AskQuickAskPlugin.id })
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.modelLibrary.settings.saveAskLauncherKeywords([AskKeyword(keyword: "fast", pluginID: plugin.id)])
        #expect(AskKeywordMatcher.match("qa hello", keywords: f.model.launcherKeywords) == nil)
        #expect(AskKeywordMatcher.match("fast hello", keywords: f.model.launcherKeywords) != nil)
    }

    @Test func blankInputAndTypingNeverSend() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, text: " \n ")
        f.model.submitQuickAsk()
        #expect(f.model.quickAsk == nil)
        f.model.launcherDraft.text = "Question"
        f.model.plugins.update(text: "Question", selection: nil, language: .english)
        #expect(await f.api.sends.isEmpty)
        #expect(f.model.canSubmitQuickAsk)
    }

    @Test func answerPreservesChatSelectionDraftAndUsesOneRequest() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.draft.text = "Keep my draft"
        let previous = f.model.selected
        prepare(f)
        f.model.launcherDraft.includeScreenshot = true
        f.model.launcherDraft.screenshot = "screen"
        f.model.launcherDraft.selection = "Explicit selection"
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        f.model.submitLauncher()
        f.model.submitLauncher()
        try await f.wait { !f.model.quickAskRunning && f.model.quickAsk?.persisted == true }
        #expect(f.model.selected == previous && f.model.selectedId == "old")
        #expect(f.model.draft.text == "Keep my draft" && opens == 0)
        #expect(f.model.quickAskAnswer == "This is the answer.")
        let requests = await f.api.sends
        #expect(requests.count == 1)
        #expect(requests.first?.text == "Explain actors")
        #expect(requests.first?.selection == "Explicit selection")
        #expect(requests.first?.image == nil && requests.first?.tools.isEmpty == true)
        #expect(requests.first?.imageResults == false)
        #expect(f.model.quickAskError == nil)
    }

    @Test func handoffKeepsConversationAndSavesDisplacedDraft() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        f.model.draft.text = "Unsent chat"
        try await answer(f)
        let id = try #require(f.model.quickAsk?.conversationId)
        var opens = 0
        f.model.onShowConversation = { opens += 1; f.model.dismissQuickAsk() }
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.selectedId == id && f.model.selected?.messages.count == 2)
        #expect(f.model.savedChatDrafts.first?.draft.text == "Unsent chat")
        #expect(f.model.quickAsk?.handedOff == true && opens == 1)
        #expect(await f.api.sends.count == 1)
        #expect(!f.model.plugins.isActive)
        f.model.draft.text = "Follow up"
        f.model.submitDraft()
        try await f.wait { !f.model.isBusy }
        #expect(f.model.selectedId == id && f.model.selected?.messages.count == 4)
        #expect(await f.api.sends.count == 2)
    }

    @Test func existingDraftRestoresAfterFollowUpHandoff() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.draft.text = "Preserved"
        prepare(f)
        try await answer(f)
        #expect(await f.model.openQuickAskInChat(focusComposer: true))
        #expect(try await f.cache.draft(key: "old", owner: "owner")?.text == "Preserved")
        await f.model.select("old")
        #expect(f.model.draft.text == "Preserved")
    }

    @Test func progressAndHandoffShareTheSameSnapshot() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        await f.api.setStreamsOnSend(true)
        f.model.submitQuickAsk()
        try await f.wait { f.model.quickAskConversation?.run?.status == "running" }
        var value = try #require(f.model.quickAskConversation)
        value.revision += 1
        value.run?.status = "running"
        value.run?.preview = "Partial answer"
        await f.api.seed(value)
        try await f.model.accept(value, route: try #require(f.model.credentials(for: value.id)))
        #expect(f.model.quickAskRunning && f.model.quickAskAnswer == "Partial answer")
        #expect(await f.model.openQuickAskInChat(focusComposer: true))
        f.model.dismissQuickAsk()
        #expect(f.model.quickAsk?.stopped == false)
        #expect(f.model.selectedId == value.id)
        value.revision += 1
        value.run?.preview = "Partial answer continues"
        await f.api.seed(value)
        try await f.model.accept(value, route: try #require(f.model.credentials(for: value.id)))
        #expect(f.model.liveProgress(try #require(f.model.selected))?.text == "Partial answer continues")
        #expect(await f.api.sends.count == 1)
    }

    @Test func failuresKeepQuestionAndDoNotResendOnRepeatedReturn() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        await f.api.setFailSend(true)
        f.model.submitQuickAsk()
        try await f.wait { f.model.quickAskError != nil && !f.model.quickAskRunning }
        let id = f.model.quickAsk?.conversationId
        #expect(f.model.launcherDraft.text == "Explain actors")
        #expect(!f.model.canSubmitQuickAsk)
        f.model.submitQuickAsk()
        #expect(f.model.quickAsk?.conversationId == id)
        #expect(await f.api.sends.isEmpty)
        #expect(await f.model.openQuickAskInChat())
        #expect(f.model.selectedId == id && f.model.error != nil)
    }

    @Test func modelAndAuthenticationFailuresRemainInline() async throws {
        let f = try AskTestFixture(authenticated: false)
        defer { f.model.resetSession() }
        f.model.plugins.enter(AskQuickAskPlugin.keywords[0])
        f.model.launcherDraft.text = "Question"
        f.model.submitQuickAsk()
        #expect(f.model.submissionIssues[true]?.offersSignIn == true)
        #expect(f.model.quickAsk == nil)
        let signedIn = try AskTestFixture()
        defer { signedIn.model.resetSession() }
        prepare(signedIn)
        signedIn.model.launcherDraft.modelRef = "missing:model"
        signedIn.model.submitQuickAsk()
        #expect(signedIn.model.quickAskError != nil)
        #expect(signedIn.model.quickAsk?.conversationId == nil)
        #expect(signedIn.model.canSubmitQuickAsk)
        #expect(await signedIn.api.sends.isEmpty)
    }

    @Test func advancedInputIsPreservedForChat() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        f.model.launcherDraft.skills = ["skill"]
        f.model.submitQuickAsk()
        #expect(f.model.quickAskError != nil && f.model.quickAsk == nil)
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.draft.skills == ["skill"] && f.model.draft.text == "Explain actors")
        #expect(await f.api.sends.isEmpty)
    }

    @Test func localAndTemporaryStorageKeepTheirSemantics() async throws {
        for temporary in [false, true] {
            let f = try AskTestFixture()
            defer { f.model.resetSession() }
            prepare(f)
            if !temporary {
                var registry = f.model.modelLibrary.registry
                registry.providers.append(.init(id: "endpoint:test", name: "Test", baseURL: "https://example.invalid/v1",
                                                models: [.init(id: "test", name: "Test", reference: "custom:test")]))
                try f.model.modelLibrary.commit(registry)
                f.model.launcherDraft.modelRef = "custom:test"
            }
            f.model.launcherDraft.storesLocally = !temporary
            f.model.launcherDraft.temporary = temporary
            try await answer(f)
            let id = try #require(f.model.quickAsk?.conversationId)
            #expect(f.model.isTemporary(id) == temporary)
            if temporary {
                #expect(!f.model.conversations.contains { $0.id == id })
                #expect(try await f.cache.list(owner: "owner").isEmpty)
            } else {
                #expect(f.model.isLocal(id))
                #expect(await f.localAPI.sends.count == 1)
                #expect(await f.api.sends.isEmpty)
            }
            #expect(await f.model.openQuickAskInChat())
            #expect(f.model.isTemporary(id) == temporary)
        }
    }

    @Test func hideRestoresAnswerAndNewQuestionClearsOnlyInlineState() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        try await answer(f)
        let id = f.model.quickAsk?.conversationId
        f.model.dismissQuickAsk()
        f.model.foldLauncherKeyword()
        #expect(f.model.resetLauncherForPresentation())
        #expect(f.model.plugins.keyword?.pluginID == AskQuickAskPlugin.id)
        #expect(f.model.quickAsk?.conversationId == id)
        #expect(f.model.quickAskAnswer == "This is the answer.")
        f.model.newQuickAskQuestion()
        #expect(f.model.quickAsk == nil && f.model.launcherDraft.text.isEmpty)
        #expect(f.model.conversations.contains { $0.id == id })
        #expect(await f.api.sends.count == 1)
    }

    @Test func accountChangesHideAnswersAndRejectLateUpdates() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        try await answer(f)
        var old = try #require(f.model.quickAskConversation)
        let route = try #require(f.model.credentials(for: old.id))
        f.sessionState.owner = "other"
        #expect(f.model.quickAskConversation == nil)
        #expect(!(await f.model.openQuickAskInChat()))
        _ = f.model.credentials()
        #expect(f.model.quickAsk == nil)
        old.revision += 1
        do { try await f.model.accept(old, route: route); Issue.record("Old update accepted") }
        catch is CancellationError {} catch { Issue.record(error) }
    }

    @Test func nativeReturnSubmitsInlineAndCommandOOpensSameChat() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "qa Explain actors")
        defer { launcher.close() }
        let model = launcher.fixture.model
        var opens = 0
        model.onShowConversation = { opens += 1 }
        #expect(model.plugins.keyword?.pluginID == AskQuickAskPlugin.id)
        #expect(await launcher.fixture.api.sends.isEmpty)
        try await launcher.press(36)
        try await launcher.fixture.wait { model.quickAsk?.persisted == true && !model.quickAskRunning }
        #expect(opens == 0 && launcher.dismissed == 0)
        let id = model.quickAsk?.conversationId
        try await launcher.press(31, .command)
        #expect(opens == 1 && model.selectedId == id)
        #expect(await launcher.fixture.api.sends.count == 1)
    }

    @Test func stoppingAndHidingCancelOnlyTheInlineRun() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        await f.api.setStreamsOnSend(true)
        f.model.submitQuickAsk()
        try await f.wait { f.model.quickAskConversation?.run?.status == "running" }
        var value = try #require(f.model.quickAskConversation)
        value.revision += 1
        value.run?.status = "running"
        value.run?.preview = "Partial"
        await f.api.seed(value)
        try await f.model.accept(value, route: try #require(f.model.credentials(for: value.id)))
        #expect(f.model.quickAskRunning)
        f.model.newQuickAskQuestion()
        #expect(f.model.quickAsk?.conversationId == value.id)
        f.model.dismissQuickAsk()
        try await f.wait { f.model.quickAskConversation?.run?.status == "cancelled" }
        #expect(f.model.quickAsk?.stopped == true)
        #expect(f.model.quickAskAnswer == "Partial")
        f.model.stopQuickAsk()
        #expect(await f.api.sends.count == 1)
    }

    @Test func asynchronousModelValidationFailureCanBeCorrected() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        f.model.launcherDraft.modelRef = "cloud:removed"
        await f.api.setFailModels(true)
        f.model.submitQuickAsk()
        try await f.wait { f.model.submissionPreflights[true] == nil }
        #expect(f.model.quickAsk?.conversationId == nil && f.model.quickAskError != nil)
        #expect(await f.api.sends.isEmpty)
        f.model.launcherDraft.modelRef = nil
        await f.api.setFailModels(false)
        try await answer(f)
    }

    @Test func cancellationDuringPreflightCannotCreateAConversation() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        f.model.launcherDraft.modelRef = "cloud:default"
        // A named Cloud model reserves an asynchronous model-validation operation.
        f.model.launcherDraft.modelRef = "cloud:removed"
        f.model.submitQuickAsk()
        #expect(f.model.quickAskRunning)
        f.model.stopQuickAsk()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.quickAsk?.conversationId == nil)
        #expect(await f.api.sends.isEmpty)
        #expect(!(await f.model.openQuickAskInChat()))
    }

    @Test func keywordSettingsExposeEditableQuickQuestions() throws {
        #expect(AskKeywordKind(pluginID: AskQuickAskPlugin.id) == .quickAsk)
        #expect(AskKeywordKind.quickAsk.pluginID == AskQuickAskPlugin.id)
        #expect(AskKeywordKind.quickAsk.title == L("ask.quickAsk.title"))
        #expect(AskKeywordKind.quickAsk.symbol == AskQuickAskPlugin().symbol)
        #expect(AskKeywordSection.typeflux.kinds.contains(.quickAsk))
        _ = AskKeywordKind.quickAsk.tint
        var draft = AskKeywordDraft(editing: AskQuickAskPlugin.keywords[0])
        #expect(draft.titlePlaceholder.isEmpty && draft.displayName == L("ask.quickAsk.title"))
        #expect(draft.fieldProblem == nil)
        draft.keyword = "question"
        let edited = draft.result()
        #expect(edited.pluginID == AskQuickAskPlugin.id && edited.keyword == "question")
        let rows = AskKeywordListPresentation.rows(keywords: AskPluginRegistry.defaultKeywords,
                                                   interface: .english, secondLanguage: "ja")
        let row = try #require(rows.first { $0.kind == .quickAsk })
        #expect(row.keyword == "qa" && row.name == L("ask.quickAsk.title"))
        #expect(row.summary == L("ask.settings.keywords.kind.quickAsk.hint"))
        var keyword = AskQuickAskPlugin.keywords[0]
        keyword.enabled = false
        #expect(AskKeywordMatcher.match("qa Question", keywords: [keyword]) == nil)
    }

    @Test func imeReturnDoesNotSendAndShiftReturnAddsANewline() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "qa Question")
        defer { launcher.close() }
        launcher.editor.setSelectedRange(NSRange(location: launcher.editor.string.utf16.count, length: 0))
        let newline = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                   timestamp: 0, windowNumber: launcher.window.windowNumber, context: nil,
                                                   characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        launcher.editor.keyDown(with: newline)
        #expect(launcher.editor.string.contains("\n"))
        #expect(await launcher.fixture.api.sends.isEmpty)
        launcher.editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        try await launcher.press(36)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func nativeEscapeStopsThenExitsQuickAsk() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "qa Explain actors")
        defer { launcher.close() }
        let model = launcher.fixture.model
        await launcher.fixture.api.setStreamsOnSend(true)
        try await launcher.press(36)
        try await launcher.fixture.wait { model.quickAskConversation?.run?.status == "running" }
        try await launcher.press(53)
        try await launcher.fixture.wait { model.quickAskConversation?.run?.status == "cancelled" }
        #expect(model.plugins.isActive && model.quickAsk?.stopped == true)
        #expect(launcher.dismissed == 0)
        try await launcher.press(53)
        #expect(!model.plugins.isActive && model.quickAsk?.restoreOnPresentation == false)
        try await launcher.press(53)
        #expect(launcher.dismissed == 1)
        #expect(await launcher.fixture.api.sends.count == 1)
    }

    @Test func namedModelValidationSurvivesIndependentChatNavigation() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        await f.api.setCloudModels([.init(id: "chosen", name: "Chosen")])
        f.model.launcherDraft.modelRef = "cloud:chosen"
        f.model.submitQuickAsk()
        f.model.newConversation()
        try await f.wait { f.model.quickAsk?.persisted == true && !f.model.quickAskRunning }
        #expect(f.model.quickAskAnswer == "This is the answer.")
        #expect(f.model.selectedId == nil)
        #expect(await f.api.sends.first?.modelRef == "cloud:chosen")
    }

    @Test func committedAssistantReplacesItsStreamingPreview() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        try await answer(f)
        var value = try #require(f.model.quickAskConversation)
        value.run?.assistantId = value.messages.last?.id
        value.run?.preview = "This is the answer."
        value.revision += 1
        try await f.model.accept(value, route: try #require(f.model.credentials(for: value.id)))
        #expect(f.model.quickAskAnswer == "This is the answer.")
    }

    @Test func serverFailureIsVisibleWithoutAClientException() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        await f.api.setStreamsOnSend(true)
        f.model.submitQuickAsk()
        try await f.wait { f.model.quickAskConversation?.run?.status == "running" }
        var value = try #require(f.model.quickAskConversation)
        value.run?.status = "failed"
        value.run?.error = "Model unavailable"
        value.revision += 1
        await f.api.seed(value)
        try await f.model.accept(value, route: try #require(f.model.credentials(for: value.id)))
        #expect(f.model.quickAskError == "Model unavailable")
        value.run?.errorCode = "MODEL_OUTPUT_LIMIT"
        value.revision += 1
        try await f.model.accept(value, route: try #require(f.model.credentials(for: value.id)))
        #expect(f.model.quickAskError == L("ask.failure.outputLimit"))
    }

    @Test func unexpectedToolsAreCancelledWithoutExecuting() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f)
        await f.api.setTool(.init(id: "tool", function: .init(name: "browser", arguments: "{}")))
        f.model.submitQuickAsk()
        try await f.wait { !f.model.quickAskRunning && f.model.quickAskError != nil }
        #expect(f.model.quickAskConversation?.run?.status == "cancelled")
        #expect(f.tools.executions == 0 && f.tools.definitionRequests.isEmpty)
        #expect(f.model.pendingApprovals.isEmpty)
    }

    @Test(arguments: ["followUp", "open"])
    func visibleButtonsCopyResetAndOpenTheSameConversation(destination: String) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "qa Explain actors")
        defer { launcher.close() }
        let pasteboard = NSPasteboard(name: .init("quick-ask-test-" + UUID().uuidString))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = pasteboard
        defer { AskQuickResults.pasteboard = previous; pasteboard.releaseGlobally() }
        let model = launcher.fixture.model
        var opens = 0
        model.onShowConversation = { opens += 1 }
        try await press("send", in: launcher.window)
        try await launcher.fixture.wait { model.quickAsk?.persisted == true && !model.quickAskRunning }
        try await press("copy", in: launcher.window)
        #expect(pasteboard.string(forType: .string) == "This is the answer.")
        try await press("new", in: launcher.window)
        #expect(model.quickAsk == nil && model.launcherDraft.text.isEmpty)
        model.launcherDraft.text = "Another question"
        try await Task.sleep(for: .milliseconds(50))
        try await press("send", in: launcher.window)
        try await launcher.fixture.wait { model.quickAsk?.persisted == true && !model.quickAskRunning }
        let id = model.quickAsk?.conversationId
        try await press(destination, in: launcher.window)
        #expect(opens == 1 && model.selectedId == id)
        #expect(await launcher.fixture.api.sends.count == 2)
    }

    private func press(_ action: String, in window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func find(_ node: Any) -> NSObject? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == "ask.quickAsk." + action { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        var button: NSObject?
        for _ in 0..<30 where button == nil {
            seen = []
            button = find(window)
            if button == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let found = try #require(button, "Missing quick ask button: \(action)")
        let frame = try #require((found.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
        #expect(frame.width > 0 && frame.height > 0)
        #expect(window.frame.contains(frame), "Actions must remain inside a short launcher window")
        // AppKit mouseDown tracks until mouseUp synchronously; AX invokes the same action without a nested event loop.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        #expect(found.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let activate = unsafeBitCast(found.method(for: selector), to: Press.self)
        #expect(activate(found, selector))
        try await Task.sleep(for: .milliseconds(60))
    }

    @Test func renderInlineAnswerInBothAppearances() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "qa 如何理解 Swift Actor？")
            defer { launcher.close() }
            launcher.window.appearance = NSAppearance(named: appearance)
            try await launcher.press(36)
            try await launcher.fixture.wait { launcher.fixture.model.quickAsk?.persisted == true && !launcher.fixture.model.quickAskRunning }
            var value = try #require(launcher.fixture.model.quickAskConversation)
            value.messages[value.messages.count - 1].text = "Actor 用于隔离可变状态，让多个任务安全地访问同一份数据。\n\n```swift\nactor Counter {\n    var count = 0\n    func increment() { count += 1 }\n}\n```\n\n从外部调用 actor 的方法时，需要使用 `await`。"
            value.revision += 1
            try await launcher.fixture.model.accept(value, route: try #require(launcher.fixture.model.credentials(for: value.id)))
            try await Task.sleep(for: .milliseconds(300))
            let hosting = try #require(launcher.window.contentView)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("quick-ask-\(theme).png"))
            #expect(png.count > 4000)
        }
    }
}
