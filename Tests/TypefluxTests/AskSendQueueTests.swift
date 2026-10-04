import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask send queue")
@MainActor
struct AskSendQueueTests {
    private func draft(_ text: String) -> AskDraft {
        var value = AskDraft.followUp
        value.text = text
        return value
    }

    private func run(_ status: String, id: String = "run") -> AskRun {
        AskRun(id: id, deviceId: "device", status: status, steps: 1, updatedAt: Date(), tools: [], pending: [])
    }

    // MARK: - Queue rules

    @Test func queueKeepsOrderLimitsAndEdits() {
        var queue = AskSendQueue()
        #expect(queue.enqueue(draft("  "), to: "c") == nil)
        for index in 1 ... AskSendQueue.limit { #expect(queue.enqueue(draft("m\(index)"), to: "c") != nil) }
        #expect(!queue.canEnqueue("c"))
        #expect(queue.enqueue(draft("overflow"), to: "c") == nil)
        let ids = queue.messages("c").map(\.id)
        queue.update(ids[1], in: "c", draft: draft("edited"))
        #expect(queue.messages("c")[1].draft.text == "edited")
        queue.update(ids[1], in: "c", draft: draft(""))
        #expect(queue.messages("c").count == AskSendQueue.limit - 1, "an emptied message is removed")
        queue.update("missing", in: "c", draft: draft("x"))
        #expect(queue.next(for: "c")?.id == ids[0])
        queue.editing = .init(conversationId: "c", itemId: ids[0], stash: draft("typing"))
        #expect(queue.isEditing("c", itemId: ids[0]))
        #expect(queue.next(for: "c") == nil, "the first message waits while it is edited")
        queue.remove(ids[0], from: "c")
        #expect(queue.editing == nil)
        queue.pause("c")
        #expect(queue.isPaused("c"))
        #expect(queue.next(for: "c") == nil)
        queue.resume("c")
        let taken = queue.take(ids[2], from: "c")
        #expect(taken?.draft.text == "m3")
        #expect(queue.take("missing", from: "c") == nil)
        queue.putFirst(taken!, in: "c")
        #expect(queue.messages("c").first?.id == ids[2])
        queue.clear("c")
        #expect(queue.messages("c").isEmpty && !queue.isPaused("c"))
        queue.pause("d")
        let only = queue.enqueue(draft("solo"), to: "d")!
        queue.remove(only.id, from: "d")
        #expect(!queue.isPaused("d"), "an empty queue is no longer paused")
    }

    @Test func reconcileReturnsUnreadJumpsAndPausesOncePerFailedRun() {
        var queue = AskSendQueue()
        let jumped = queue.enqueue(draft("jump"), to: "c")!
        let waiting = queue.enqueue(draft("wait"), to: "c")!
        queue.markSteered(jumped, in: "c")
        queue.markSteered(jumped, in: "c")
        #expect(queue.steeredMessages("c").map(\.id) == [jumped.id])
        #expect(queue.messages("c").map(\.id) == [waiting.id])

        // Still running: nothing moves.
        queue.reconcile("c", transcript: [], run: run("running"))
        #expect(queue.steeredMessages("c").count == 1)
        // Delivered: the jump is done.
        let delivered = AskMessage(id: jumped.id, role: "user", text: "jump", createdAt: Date(), steered: true)
        queue.reconcile("c", transcript: [delivered], run: run("running"))
        #expect(queue.steeredMessages("c").isEmpty)

        // Not read before the run stopped: back to the front, and the queue pauses once.
        queue.markSteered(queue.messages("c")[0], in: "c")
        queue.reconcile("c", transcript: [], run: run("cancelled"))
        #expect(queue.messages("c").map(\.id) == [waiting.id])
        #expect(queue.isPaused("c"))
        queue.resume("c")
        queue.reconcile("c", transcript: [], run: run("cancelled"))
        #expect(!queue.isPaused("c"), "the same run does not pause again")
        queue.reconcile("c", transcript: [], run: run("failed", id: "next"))
        #expect(queue.isPaused("c"))
        queue.resume("c")
        queue.reconcile("c", transcript: [], run: run("completed", id: "done"))
        #expect(!queue.isPaused("c"))
        queue.reconcile("c", transcript: [], run: nil)

        var settled = AskSendQueue()
        settled.noteSettled("c", run: run("cancelled", id: "old"))
        settled.noteSettled("c", run: nil)
        settled.enqueue(draft("later"), to: "c")
        settled.reconcile("c", transcript: [], run: run("cancelled", id: "old"))
        #expect(!settled.isPaused("c"), "a run that ended before anything was queued never pauses it")
    }

    // MARK: - Conversation flows

    private func toolCall() -> AskToolCall {
        AskToolCall(id: UUID().uuidString, type: "function", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
    }

    /// Sends a question whose run then waits for a tool approval, so the conversation stays busy.
    private func busyConversation(_ f: AskTestFixture) async throws -> String {
        await f.api.setTool(toolCall())
        f.model.draft.text = "Question"
        f.model.submitDraft()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        await f.api.setTool(nil)
        return try #require(f.model.selectedId)
    }

    @Test func busyConversationQueuesFollowUpsAndSendsThemInOrder() async throws {
        let f = try AskTestFixture()
        let id = try await busyConversation(f)
        #expect(!f.model.canQueue, "nothing to queue yet")
        f.model.draft.text = "First follow-up"
        #expect(f.model.canQueue && f.model.canSend)
        f.model.submitDraft()
        f.model.draft.text = "Second"
        f.model.submitDraft()
        #expect(f.model.queuedMessages.map(\.draft.text) == ["First follow-up", "Second"])
        #expect(f.model.draft.text.isEmpty)

        // Editing opens the message in the composer and puts the typing aside.
        f.model.draft.text = "typing"
        let second = f.model.queuedMessages[1]
        f.model.editQueued(second.id)
        #expect(f.model.isEditingQueued)
        #expect(f.model.draft.text == "Second")
        #expect(!f.model.canQueue)
        f.model.draft.text = "Second, edited"
        f.model.submitDraft()
        #expect(!f.model.isEditingQueued)
        #expect(f.model.queuedMessages[1].draft.text == "Second, edited")
        #expect(f.model.draft.text == "typing")
        f.model.editQueued(f.model.queuedMessages[0].id)
        f.model.draft.text = "discarded"
        f.model.editQueued(f.model.queuedMessages[1].id)
        #expect(f.model.queuedMessages[0].draft.text == "discarded", "opening another message saves the open one")
        f.model.cancelQueuedEdit()
        #expect(f.model.draft.text == "typing")
        f.model.editQueued("missing")
        #expect(!f.model.isEditingQueued)

        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.queuedMessages.isEmpty && f.model.busyIds.isEmpty }
        let sends = await f.api.sends
        #expect(sends.map(\.text) == ["Question", "discarded", "Second, edited"])
        #expect(f.model.draft.text == "typing", "sending from the queue leaves the composer alone")
        #expect(f.model.selected?.messages.filter { $0.role == "user" }.map(\.text) == ["Question", "discarded", "Second, edited"])
    }

    @Test func stoppingPausesTheQueueUntilTheUserResumes() async throws {
        let f = try AskTestFixture()
        _ = try await busyConversation(f)
        f.model.draft.text = "Later"
        f.model.draft.selection = "Selected words"
        f.model.submitDraft()
        f.model.stop()
        try await f.wait { f.model.isQueuePaused }
        // The paused bar offers to resume or clear; the attachment mark shows.
        #expect(fits(AskQueueBar(model: f.model, expanded: .constant(false))) > 20)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.api.sends.count == 1)
        #expect(!f.model.canSteer)
        f.model.resumeQueue()
        try await f.wait { f.model.queuedMessages.isEmpty && f.model.busyIds.isEmpty }
        #expect(await f.api.sends.last?.text == "Later")
        #expect(!f.model.isQueuePaused)
    }

    @Test func removingAndClearingQueuedMessages() async throws {
        let f = try AskTestFixture()
        let id = try await busyConversation(f)
        for text in ["a", "b", "c"] { f.model.draft.text = text; f.model.submitDraft() }
        f.model.editQueued(f.model.queuedMessages[0].id)
        f.model.removeQueued(f.model.queuedMessages[0].id)
        #expect(!f.model.isEditingQueued)
        #expect(f.model.queuedMessages.map(\.draft.text) == ["b", "c"])
        f.model.clearQueue()
        #expect(f.model.queuedMessages.isEmpty)
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.sends.count == 1)
    }

    @Test func jumpingTheQueueHandsTheMessageToTheRunningRun() async throws {
        let f = try AskTestFixture()
        let id = try await busyConversation(f)
        await f.api.setDeliverSteers(true)
        f.model.draft.text = "Jump"
        f.model.submitDraft()
        let item = try #require(f.model.queuedMessages.first)
        #expect(f.model.canSteer)
        f.model.steerQueued(item.id)
        // The jump leaves the queue first, then the run's reply shows it delivered.
        try await f.wait { f.model.queuedMessages.isEmpty && f.model.selected?.messages.last?.id == item.id }
        let steers = await f.api.steers
        #expect(steers.map(\.id) == [item.id])
        #expect(steers.first?.runId == f.model.selected?.run?.id)
        #expect(f.model.steeredMessages.isEmpty, "the run already holds it")
        #expect(f.model.selected?.messages.last?.steered == true)
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.sends.count == 1, "a delivered jump is not sent again")
    }

    @Test func aJumpTheRunNeverReadIsSentAsTheNextTurn() async throws {
        let f = try AskTestFixture()
        let id = try await busyConversation(f)
        // Steering rejects the current approval. Hold the run at its next one
        // so the unread state remains observable until this test ends the run.
        let continuing = toolCall()
        await f.api.queueFollowUpTools([continuing])
        f.model.draft.text = "Unread"
        f.model.submitDraft()
        let item = try #require(f.model.queuedMessages.first)
        f.model.steerQueued(item.id)
        try await f.wait { !f.model.steeredMessages.isEmpty }
        #expect(f.model.steeredMessages.map(\.id) == [item.id])
        try await f.wait { f.model.pendingApprovals[id]?.id == continuing.id }
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty && f.model.steeredMessages.isEmpty && f.model.queuedMessages.isEmpty }
        try await f.wait { f.model.busyIds.isEmpty }
        let sends = await f.api.sends
        #expect(sends.last?.id == item.id, "sent with the same message ID")
        #expect(sends.last?.text == "Unread")
    }

    @Test func aFailedJumpIsReportedWhileTheRunIsStillWorking() async throws {
        let f = try AskTestFixture()
        let id = try await busyConversation(f)
        // Steering rejects the pending tool first. Keep another tool pending
        // so its result cannot complete the run before the failed steer refresh.
        let continuing = toolCall()
        await f.api.queueFollowUpTools([continuing])
        await f.api.setFailSteer(true)
        f.model.draft.text = "Rejected"
        f.model.submitDraft()
        let item = try #require(f.model.queuedMessages.first)
        f.model.steerQueued(item.id)
        try await f.wait { f.model.error != nil }
        #expect(f.model.queuedMessages.map(\.id) == [item.id])
        try await f.wait { f.model.pendingApprovals[id]?.id == continuing.id }
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty && f.model.queuedMessages.isEmpty }
    }

    // MARK: - Views

    private func fits<V: View>(_ view: V, width: CGFloat = 640) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    @Test func queueBarRendersCollapsedExpandedPausedAndEditing() async throws {
        let f = try AskTestFixture()
        let id = try await busyConversation(f)
        for text in ["First line\nsecond line", "Two", "Three"] { f.model.draft.text = text; f.model.submitDraft() }
        #expect(AskQueueBar.preview(f.model.queuedMessages[0].draft) == "First line second line")
        var references = AskDraft.followUp
        references.references = [AskReference(messageId: "m", text: "quote", question: "Why?")]
        #expect(AskQueueBar.preview(references) == "Why?")
        #expect(AskQueueBar.countText(3, paused: true) == L("ask.queue.count", 3) + " · " + L("ask.queue.paused"))
        let collapsed = fits(AskQueueBar(model: f.model, expanded: .constant(false)))
        let expanded = fits(AskQueueBar(model: f.model, expanded: .constant(true)))
        #expect(collapsed > 20)
        #expect(expanded > collapsed + 40)
        f.model.editQueued(f.model.queuedMessages[1].id)
        #expect(fits(AskComposer(model: f.model, launcher: false)) > 60)
        #expect(fits(AskQueueEditingHeader(index: 2, keepsDraft: true)) > 10)
        var saved = false, cancelled = false
        let actions = AskQueueEditActions(canSave: true, onCancel: { cancelled = true }, onSave: { saved = true })
        #expect(fits(actions, width: 200) > 20)
        actions.onSave(); actions.onCancel()
        #expect(saved && cancelled)
        f.model.cancelQueuedEdit()
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty && f.model.queuedMessages.isEmpty }
        #expect(fits(AskQueueBar(model: f.model, expanded: .constant(false))) == 0)
        let transcript = NSHostingView(rootView: AskConversationView(model: f.model).frame(width: 900, height: 700))
        transcript.layoutSubtreeIfNeeded()
        #expect(transcript.fittingSize.height > 0)
    }
}
