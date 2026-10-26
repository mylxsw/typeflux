import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Transcript status stability", .serialized, .exclusiveUIState)
@MainActor
struct AskTranscriptStabilityTests {
    @Test func visibleIdentitySurvivesToolPreambleAndDoesNotCollideWithActivity() {
        let message = AskMessage(id: "answer", role: "assistant", text: "Checking", createdAt: .distantPast)
        let text = AskTranscriptItem(kind: .message(message))
        let note = AskTranscriptItem(kind: .message(message), isProgress: true)
        let activity = AskTranscriptItem(kind: .activity(.init(id: message.id, messages: [message])))
        #expect(text.viewID == note.viewID)
        #expect(text.viewID != activity.viewID)
    }

    @Test func liveStateRetainsOnlyTheCurrentUncommittedStep() {
        let state = AskTranscriptLiveMessageState()
        var run = AskRun(id: "run", deviceId: "device", status: "running", steps: 1,
                         updatedAt: .distantPast, tools: [], pending: [], assistantId: "live")
        var message = AskMessage(id: "live", role: "assistant", text: "Checking", createdAt: .distantPast, runId: "run")
        func resolve(_ message: AskMessage?, conversation: String? = "chat", committed: Bool = false) -> AskMessage? {
            state.resolve(conversationID: conversation, run: run, message: message, isCommitted: { _ in committed })
        }
        #expect(resolve(message) == message)
        #expect(resolve(nil) == message)
        var empty = message; empty.text = " \n"
        #expect(resolve(empty) == message)
        var stale = message; stale.id = "previous"
        #expect(resolve(stale) == message)
        #expect(resolve(nil, committed: true) == nil)
        #expect(resolve(nil) == nil)
        #expect(resolve(message) == message)
        #expect(resolve(nil, conversation: "other") == nil)
        #expect(resolve(message) == message)
        run.assistantId = "next"
        #expect(resolve(nil) == nil)
        run.assistantId = "live"
        #expect(resolve(message) == message)
        run.id = "new-run"
        #expect(resolve(nil) == nil)
        message.runId = "new-run"
        #expect(resolve(message) == message)
        run.status = "completed"
        #expect(resolve(nil) == nil)
        #expect(resolve(message) == message)
        #expect(resolve(message, committed: true) == nil)
        run.status = "running"
        #expect(resolve(nil) == nil)
        #expect(resolve(message) == message)
        #expect(resolve(nil, conversation: nil) == nil)
    }

    @Test func continuePendingTaskUsesRetryInsteadOfOnlyReloadingHistory() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        var c = AskConversation(id: "pending-task", title: "Website", revision: 1, updatedAt: .distantPast,
            messages: [.init(id: "user", role: "user", text: "Build website", createdAt: .distantPast)])
        c.run = .init(id: "run", deviceId: "device", status: "completed", steps: 174,
            updatedAt: .distantPast, tools: [], pending: [])
        c.run?.plan = [.init(step: "Verify interactions", status: "pending")]
        await f.api.seed(c)
        await f.model.select(c.id)
        #expect(f.model.selected?.run?.canContinueTask == true)
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let host = NSHostingView(rootView: AskConversationView(model: f.model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 750),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func value(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func find(_ object: NSObject) -> NSRect? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let title = value(object, "accessibilityLabel") as? String ?? value(object, "accessibilityTitle") as? String
            if title == L("ask.resume"), value(object, "accessibilityRole") as? String == "AXButton",
               let frame = value(object, "accessibilityFrame") as? NSValue, frame.rectValue.height > 0 {
                return frame.rectValue
            }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] {
                if let frame = find(child) { return frame }
            }
            return nil
        }
        let frame = try #require(find(window) ?? find(host), "Pending tasks must expose a native Continue button")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/typeflux-agent-continue.png"))
        }
        let local = window.convertFromScreen(frame)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: local.midX, y: local.midY),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
        try await f.wait { f.model.busyIds.isEmpty && (f.model.selected?.revision ?? 0) > c.revision }
        #expect(await f.api.retryModels.count == 1)
        #expect(f.tools.executions == 0)
        #expect(f.model.error == nil)
    }

    @Test func terminalSnapshotDoesNotResurrectReasoningOnlyPlaceholder() {
        let state = AskTranscriptLiveMessageState()
        var run = AskRun(id: "run", deviceId: "device", status: "running", steps: 1,
                         updatedAt: .distantPast, tools: [], pending: [], assistantId: "live")
        let thought = AskMessage(id: "live", role: "assistant", text: "", createdAt: .distantPast,
                                 reasoning: "Checking", reasoningMilliseconds: 1000, runId: "run")
        #expect(state.resolve(conversationID: "chat", run: run, message: thought, isCommitted: { _ in false }) != nil)
        run.status = "completed"
        #expect(state.resolve(conversationID: "chat", run: run, message: thought, isCommitted: { _ in false }) == nil)
        run.assistantId = nil
        #expect(state.resolve(conversationID: "chat", run: run, message: nil, isCommitted: { _ in false }) == nil)
    }

    @Test func stopReasonIsNotRepeatedBesideAnIdenticalAnswer() {
        let call = AskToolCall(id: "call", function: .init(name: "files", arguments: "{}"))
        let message = AskMessage(id: "tool", role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: "run")
        let group = AskActivityGroup(id: "group", messages: [message])
        var run = AskRun(id: "run", deviceId: "device", status: "completed", steps: 1,
                         updatedAt: .distantPast, tools: [], pending: [])
        run.taskResolution = .init(outcome: "blocked", reason: "Specific missing dependency")
        let answer = AskMessage(id: "answer", role: "assistant", text: "Specific missing dependency", createdAt: .distantPast, runId: "run")
        #expect(AskActivity.resolution(for: group, run: run, isLatest: true, answers: [answer]) == nil)
        #expect(AskActivity.resolution(for: group, run: run, isLatest: true, answers: []) == run.taskResolution)
    }

    @Test func emptyStepsPreserveGroupingAndOutcomeAttribution() {
        let call = AskToolCall(id: "call", function: .init(name: "files", arguments: "{}"))
        let first = AskMessage(id: "first", role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: "run")
        let empty = AskMessage(id: "empty", role: "assistant", text: "", createdAt: .distantPast, runId: "run")
        var next = first; next.id = "next"
        let rows = AskActivity.items([first, empty, next], results: [])
        #expect(rows.count == 1)
        if case let .activity(group) = rows.first?.kind { #expect(group.messageIds == ["first", "next"]) }
        else { Issue.record("Empty transport steps must not split the activity") }
        var image = empty; image.image = "data:image/png;base64,AA=="
        #expect(image.hasTranscriptContent)
        var reasoning = empty; reasoning.reasoning = "Thinking"
        #expect(reasoning.hasTranscriptContent)
        let cache = AskActivityOutputCache()
        _ = cache.prepare(conversationID: "chat", messages: [first], results: [], changes: [:])
        #expect(cache.containsCommittedMessage(first.id))
        #expect(!cache.containsCommittedMessage(empty.id))
        #expect(cache.appendingProgress(empty) == AskActivity.items([first, empty], results: []))
        #expect(cache.appendingProgress(next) == rows)
        let changes = [first.id: [AskWorkspaceFileChange(path: "outputs/site.html", kind: .added)]]
        _ = cache.prepare(conversationID: "chat", messages: [first], results: [], changes: changes)
        let incremental = cache.appendingProgress(empty)
        #expect(incremental == AskActivity.items([first, empty], results: [], fileChanges: changes))
        if case let .outcome(outcome) = incremental.last?.kind {
            #expect(outcome.messageIDs == [first.id, empty.id])
            #expect(outcome.changes.count == 1)
        } else { Issue.record("File results must survive an empty step") }
    }

    @Test func previousRunsDoNotHideNewWaitingAndModelCacheRefreshes() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let call = AskToolCall(id: "call", function: .init(name: "files", arguments: "{}"))
        var value = AskConversation(id: "waiting-cache", title: "Waiting", revision: 1, updatedAt: .distantPast,
            messages: [.init(id: "old", role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: "old-run")])
        value.run = .init(id: "run", deviceId: "device", status: "running", steps: 1,
                         updatedAt: .distantPast, tools: [], pending: [], assistantId: "live")
        await f.api.seed(value); await f.model.select(value.id)
        #expect(!f.model.runHasToolActivity)
        #expect(f.model.showsResponseWaiting)
        #expect(f.model.cachedRunHasToolActivity == false)
        value.messages.append(.init(id: "step", role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: "run"))
        value.revision += 1
        try await f.model.accept(value, route: #require(f.model.credentials(for: value.id)))
        #expect(f.model.runHasToolActivity)
        #expect(!f.model.showsResponseWaiting)
        #expect(AskResponseWaiting.isVisible(phase: .working(step: 1), pendingSubmission: true, run: value.run,
            messages: value.messages, progress: nil, hasError: false))
    }

    @Test func emptyProgressDoesNotSplitAnExistingActivity() {
        let call = AskToolCall(id: "first-call", function: .init(name: "files", arguments: "{}"))
        let step = AskMessage(id: "first", role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: "run")
        let empty = AskMessage(id: "next", role: "assistant", text: "", createdAt: .distantPast, runId: "run")
        let cache = AskActivityOutputCache()
        let initial = cache.prepare(conversationID: "chat", messages: [step], results: [], changes: [:])
        #expect(cache.appendingProgress(empty) == initial)
        #expect(AskActivity.items([step, empty], results: []) == initial)
    }

    @Test func toolProgressDoesNotShowASecondWaitingIndicator() {
        let run = AskRun(id: "run", deviceId: "device", status: "running", steps: 1,
                         updatedAt: .distantPast, tools: [], pending: [], assistantId: "live")
        let call = AskToolCall(id: "call", function: .init(name: "files", arguments: "{}"))
        #expect(!AskResponseWaiting.isVisible(phase: .working(step: 1), pendingSubmission: false, run: run,
            messages: [], progress: .init(toolCalls: [call]), hasError: false))
        let committed = AskMessage(id: "previous", role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: "run")
        #expect(!AskResponseWaiting.isVisible(phase: .working(step: 2), pendingSubmission: false, run: run,
            messages: [committed], progress: nil, hasError: false))
    }

    @Test func streamedTextAndToolHandoffsKeepTheMountedTextAndHeight() async throws {
        let suite = "transcript-stability-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try AskTestFixture(defaults: defaults)
        defer { f.model.resetSession() }
        var value = AskConversation(id: "stability", title: "Status stability", revision: 1, updatedAt: .distantPast,
            messages: [.init(id: "question", role: "user", text: "Build the website", createdAt: .distantPast, runId: "run")])
        value.run = .init(id: "run", deviceId: "device", status: "running", steps: 1,
                         updatedAt: .distantPast, tools: [], pending: [], assistantId: "live")
        await f.api.seed(value)
        await f.model.select(value.id)
        f.model.externallyDrivenConversations.insert(value.id)
        let host = NSHostingView(rootView: AskConversationView(model: f.model).defaultAppStorage(defaults))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        func progress(_ progress: AskStreamProgress?) {
            f.model.applyFeatureQuickProgress(.init(owner: f.model.owner, id: value.id, runID: "run", complete: false, progress: progress))
        }
        let text = "Checking the existing website before writing the script."
        progress(.init(text: text))
        try await settle()
        let editor = try #require(descendants(host, AskTranscriptText.Editor.self).first { $0.string == text })
        let call = AskToolCall(id: "call", function: .init(name: "files", arguments: "{}"))
        progress(.init(text: text, toolCalls: [call]))
        try await settle()
        let afterTool = try #require(descendants(host, AskTranscriptText.Editor.self).first { $0.string == text })
        #expect(afterTool === editor, "A text-to-tool transition must not remount and reparse the same text")
        let scroll = try #require(descendants(host, NSScrollView.self).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        let document = try #require(scroll.documentView)
        let height = document.frame.height
        // Progress and durable snapshots travel separately. A transport gap is not a deletion.
        for _ in 0..<3 {
            progress(nil); try await settle()
            #expect(abs(document.frame.height - height) <= 1, "Transport gaps must not collapse the transcript")
            #expect(descendants(host, AskTranscriptText.Editor.self).contains { $0 === editor })
            progress(.init(text: text, toolCalls: [call])); try await settle()
            #expect(abs(document.frame.height - height) <= 1)
        }
        value.revision += 1
        value.messages.append(.init(id: "live", role: "assistant", text: text, toolCalls: [call], createdAt: .distantPast, runId: "run"))
        try await f.model.accept(value, route: #require(f.model.credentials(for: value.id)))
        progress(nil); try await settle()
        #expect(abs(document.frame.height - height) <= 1, "Committing identical content must not change layout")
        #expect(descendants(host, AskTranscriptText.Editor.self).contains { $0 === editor })
        print("TRANSCRIPT_STABILITY height=\(height) final=\(document.frame.height)")
    }
}
