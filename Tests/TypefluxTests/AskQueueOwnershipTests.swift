import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// A deterministic suspension, including a signal that the callback actually entered.
private actor QueueGate {
    private var entered = false
    private var opened = false
    private var cancelled = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entrants.forEach { $0.resume() }; entrants = []
        if !opened {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: { Task { await self.markCancelled() } }
        }
    }
    func untilEntered() async {
        if !entered { await withCheckedContinuation { entrants.append($0) } }
    }
    private func markCancelled() {
        cancelled = true
        cancellationWaiters.forEach { $0.resume() }; cancellationWaiters = []
    }
    func untilCancelled() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiters.append($0) } }
    }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@Suite("Queue ownership", .exclusiveUIState)
@MainActor
struct AskQueueOwnershipTests {
    private func draft(_ text: String) -> AskDraft { var draftValue = AskDraft.followUp; draftValue.text = text; return draftValue }
    private func run(_ status: String, id: String = "original") -> AskRun {
        .init(id: id, deviceId: "device", status: status, steps: 2, updatedAt: Date(), tools: [], pending: [])
    }
    private func prepare(local: Bool = false, cacheOverride: (any AskCaching)? = nil) async throws -> AskTestFixture {
        let defaults = try #require(UserDefaults(suiteName: "queue-ownership-" + UUID().uuidString))
        if local {
            let profile = AskModelProfile(name: "Fixture", baseURL: "https://fixture.invalid/v1", model: "fixture")
            defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let fixture = try AskTestFixture(modelLibrary: library, cacheOverride: cacheOverride)
        let value = AskConversation(id: "queue-ownership", title: "Queue", revision: 1, updatedAt: Date(), messages: [], run: run("running"))
        if local { fixture.model.registerLocalHistory([.init(id: value.id, title: value.title, updatedAt: value.updatedAt)]) }
        await (local ? fixture.localAPI : fixture.api).seed(value)
        await fixture.model.select(value.id)
        return fixture
    }
    private func enqueue(_ text: String, _ fixture: AskTestFixture) throws -> AskQueuedMessage {
        fixture.model.draft.text = text; fixture.model.submitDraft()
        return try #require(fixture.model.queuedMessages.last)
    }
    private func publish(_ status: String, _ fixture: AskTestFixture, revision: Int64 = 10, runID: String = "original") async throws {
        var value = try #require(fixture.model.selected)
        value.run = run(status, id: runID); value.revision = revision
        await (fixture.model.isLocal(value.id) ? fixture.localAPI : fixture.api).seed(value)
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
    }

    @Test(arguments: ["running", "waiting_tool", "waiting_inference", "paused_credits", "future", ""])
    func knownAndUnknownActiveStatesRetainFollowUps(_ status: String) {
        let runValue = run(status)
        let result = AskQueueDisposition.resolve(run: runValue, recoveryBlocked: false, submitting: false,
            steering: false, pendingApproval: false, deviceID: "device", paused: false, hasItems: true)
        let expected: AskQueueDisposition = status == "paused_credits" ? .blocked(.credits)
            : ["future", ""].contains(status) ? .blocked(.recovery) : .blocked(.active)
        #expect(result == expected)
    }

    @Test func dispositionGatesAreSharedAndOrdered() {
        func resolve(_ runValue: AskRun? = nil, recovery: Bool = false, submit: Bool = false, steer: Bool = false,
                     approval: Bool = false, pause: Bool = false, items: Bool = true) -> AskQueueDisposition {
            .resolve(run: runValue, recoveryBlocked: recovery, submitting: submit, steering: steer,
                     pendingApproval: approval, deviceID: "device", paused: pause, hasItems: items)
        }
        #expect(resolve() == .ready)
        #expect(resolve(items: false) == .empty)
        #expect(resolve(recovery: true, submit: true, approval: true) == .blocked(.recovery))
        #expect(resolve(approval: true) == .blocked(.approval))
        #expect(resolve(submit: true) == .blocked(.flight))
        #expect(resolve(steer: true) == .blocked(.flight))
        #expect(resolve(pause: true) == .blocked(.paused))
        for status in ["completed", "failed", "cancelled"] { #expect(resolve(run(status)) == .ready) }
        var remote = run("waiting_tool"); remote.deviceId = "other"
        #expect(resolve(remote) == .blocked(.otherDevice))
        remote.status = "waiting_inference"; #expect(resolve(remote) == .blocked(.otherDevice))
        remote.status = "running"; #expect(resolve(remote) == .blocked(.active))
    }

    @Test func claimsReserveCapacityAndNeverRestoreRemovedOrEditedIntent() throws {
        var queue = AskSendQueue()
        for index in 0 ..< AskSendQueue.limit { queue.enqueue(draft("item \(index)"), to: "c", id: "\(index)") }
        let claimResult = queue.claim("0", in: "c", runID: "run")
        let claim = try #require(claimResult)
        #expect(queue.claim("0", in: "c") == nil)
        queue.update("0", in: "c", draft: draft("must not edit"))
        #expect(queue.messages("c").first?.draft == claim.item.draft)
        queue.remove("0", from: "c")
        #expect(!queue.canEnqueue("c"))
        queue.restore(claim, in: "c")
        #expect(queue.messages("c").count == 4)
        #expect(!queue.owns(claim, in: "c"))
        queue.release(claim, in: "c")
        #expect(queue.canEnqueue("c"))
        let nextResult = queue.claim("1", in: "c")
        let next = try #require(nextResult)
        queue.clear("c"); queue.restore(next, in: "c")
        #expect(queue.messages("c").isEmpty)
        queue.release(next, in: "c")
        queue.enqueue(draft("new"), to: "c", id: "1")
        let replacementResult = queue.claim("1", in: "c")
        let replacement = try #require(replacementResult)
        queue.release(next, in: "c")
        #expect(queue.owns(replacement, in: "c"))
        queue.restore(replacement, in: "c")
        #expect(queue.isPaused("c") && queue.messages("c").first?.draft.text == "new")
        queue.release(replacement, in: "c")
    }

    @Test func consumptionDeduplicatesQueuedAndSupplementsWithOriginalRunIdentity() throws {
        var queue = AskSendQueue()
        let itemResult = queue.enqueue(draft("original"), to: "c", id: "item")
        let item = try #require(itemResult)
        queue.markSteered(item, in: "c", runID: "original")
        let wrong = AskMessage(id: item.id, role: "user", text: "other", createdAt: Date(), runId: "replacement")
        queue.reconcile("c", transcript: [wrong], run: run("running"))
        #expect(queue.steeredMessages("c").count == 1)
        queue.reconcile("c", transcript: [], run: run("failed", id: "replacement"))
        #expect(queue.steeredMessages("c").count == 1)
        queue.reconcile("c", transcript: [], run: run("failed"))
        #expect(queue.isPaused("c") && queue.messages("c").map(\.id) == [item.id])
        queue.resume("c"); queue.reconcile("c", transcript: [], run: run("failed"))
        #expect(!queue.isPaused("c"))
        queue.markSteered(item, in: "c", runID: "original")
        queue.reconcile("c", transcript: [], run: run("failed"))
        #expect(queue.isPaused("c"), "newly restored intent pauses even after an earlier settlement")
        let consumed = AskMessage(id: item.id, role: "user", text: "original", createdAt: Date(), runId: "original")
        queue.reconcile("c", transcript: [consumed], run: run("failed"))
        #expect(queue.messages("c").isEmpty && queue.steeredMessages("c").isEmpty)
        queue.enqueue(draft("ordinary"), to: "c", id: "normal")
        queue.reconcile("c", transcript: [.init(id: "normal", role: "user", text: "ordinary", createdAt: Date())], run: nil)
        #expect(queue.messages("c").isEmpty)
    }

}

extension AskQueueOwnershipTests {
    @Test(arguments: [false, true], ["failed", "cancelled"])
    func terminalFailurePausesAndExplicitResumeSendsExactlyOnce(local: Bool, status: String) async throws {
        let fixture = try await prepare(local: local)
        defer { fixture.model.resetSession() }
        let item = try enqueue("keep exact", fixture)
        fixture.model.draft.text = "composer stays"
        try await publish(status, fixture)
        #expect(fixture.model.isQueuePaused && fixture.model.queuedMessages.map(\.id) == [item.id])
        try await publish(status, fixture)
        fixture.model.resumeQueue(); fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.queuedMessages.isEmpty }
        #expect(await (local ? fixture.localAPI : fixture.api).sends.map(\.id) == [item.id])
        #expect(fixture.model.draft.text == "composer stays")
        try await publish(status, fixture, revision: 2)
        #expect(await (local ? fixture.localAPI : fixture.api).sends.count == 1)
    }

    @Test(arguments: [false, true])
    func completedFIFOAdvancesOnceDespiteRepeatedOlderSnapshots(local: Bool) async throws {
        let fixture = try await prepare(local: local)
        defer { fixture.model.resetSession() }
        let first = try enqueue("first", fixture), second = try enqueue("second", fixture)
        var terminal = try #require(fixture.model.selected)
        terminal.run = run("completed"); terminal.revision = 10
        await (local ? fixture.localAPI : fixture.api).seed(terminal)
        let route = try #require(fixture.model.credentials(for: terminal.id))
        try await fixture.model.accept(terminal, route: route)
        try await fixture.model.accept(terminal, route: route)
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.queuedMessages.isEmpty }
        terminal.revision = 3
        try await fixture.model.accept(terminal, route: route)
        #expect(await (local ? fixture.localAPI : fixture.api).sends.map(\.id) == [first.id, second.id])
    }

    @Test(arguments: ["remove", "clear", "stop", "reset", "account", "delete"])
    func heldSteerCannotResurrectInvalidatedIntent(_ action: String) async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        await fixture.api.setBeforeSteer { await gate.wait() }
        let item = try enqueue("supplement", fixture)
        fixture.model.steerQueued(item.id)
        await gate.untilEntered()
        fixture.model.editQueued(item.id)
        #expect(!fixture.model.isEditingQueued)
        switch action {
        case "remove": fixture.model.removeQueued(item.id)
        case "clear": fixture.model.clearQueue()
        case "stop": fixture.model.stop()
        case "reset": fixture.model.resetSession()
        case "account": fixture.sessionState.owner = "new-owner"; fixture.model.resetSession()
        default: try await fixture.model.delete(#require(fixture.model.selectedId))
        }
        await gate.release()
        // Collect the actual held callback before asserting; no timing-based race setup.
        await fixture.api.setBeforeSteer(nil)
        if ["remove", "clear", "reset", "account", "delete"].contains(action) {
            #expect(fixture.model.queuedMessages.isEmpty && fixture.model.steeredMessages.isEmpty)
        } else if action == "stop" { #expect(fixture.model.isQueuePaused) }
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func authoritativeConsumptionBeforeHeldSteerReplyCannotBecomePendingAgain() async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        await fixture.api.setDeliverSteers(true)
        await fixture.api.setAfterSteer { await gate.wait() }
        let item = try enqueue("consumed", fixture)
        fixture.model.steerQueued(item.id)
        await gate.untilEntered()
        let confirmed = try await fixture.api.conversation(id: #require(fixture.model.selectedId), token: "token")
        try await fixture.model.accept(confirmed, route: #require(fixture.model.credentials()))
        #expect(fixture.model.queuedMessages.isEmpty && fixture.model.steeredMessages.isEmpty)
        await gate.release()
        await fixture.api.setAfterSteer(nil)
        #expect(fixture.model.queuedMessages.isEmpty && fixture.model.steeredMessages.isEmpty)
    }

    @Test func steerErrorRetainsExactIntentAndNeverFallsBackToReplacementRun() async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        await fixture.api.setBeforeSteer { await gate.wait() }
        await fixture.api.setFailSteer(true)
        let item = try enqueue("uncertain", fixture)
        fixture.model.steerQueued(item.id)
        await gate.untilEntered()
        try await publish("completed", fixture, runID: "replacement")
        await gate.release()
        try await fixture.wait { fixture.model.steeringIds.isEmpty }
        #expect(fixture.model.isQueuePaused && fixture.model.queuedMessages == [item])
        #expect(await fixture.api.sends.isEmpty)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.steeringIds.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.queuedMessages == [item])
    }

    @Test func uncertainSendUsesOnlyPendingRequestAndRetainsDraftOnCancellation() async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        let item = try enqueue("exact queued text", fixture)
        fixture.model.draft.text = "new composer text"
        await fixture.api.setBeforeSend { await gate.wait() }
        try await publish("completed", fixture)
        await gate.untilEntered()
        fixture.model.stop()
        await gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.hasPendingSubmission && fixture.model.isQueuePaused)
        #expect(fixture.model.queuedMessages == [item])
        #expect(fixture.model.draft.text == "new composer text")
        await fixture.api.setBeforeSend(nil)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.queuedMessages.isEmpty }
        let sends = await fixture.api.sends
        #expect(Set(sends.map(\.id)) == [item.id])
        #expect(sends.allSatisfy { $0.text == item.draft.text })
    }

    @Test(arguments: ["folder", "model", "size"])
    func queuedPreAdmissionFailuresRetainExactDraftWithoutChangingComposer(_ failure: String) async throws {
        let fixture = try await prepare()
        defer { fixture.model.resetSession() }
        fixture.model.draft.text = failure == "size" ? String(repeating: "x", count: 32001) : "preserve attachments and selection"
        fixture.model.draft.selection = "selected words"
        if failure == "model" { fixture.model.draft.modelRef = "custom:missing" }
        if failure == "folder" {
            fixture.model.draft.attachments = [.init(kind: .folder, name: "Folder", path: "/missing-fixture-folder")]
            fixture.tools.folderStagingError = AskLocalError.message("Folder is unavailable")
        }
        fixture.model.submitDraft()
        let original = try #require(fixture.model.queuedMessages.first)
        fixture.model.draft.text = "untouched composer"
        try await publish("completed", fixture)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages == [original])
        #expect(fixture.model.isQueuePaused && fixture.model.draft.text == "untouched composer")
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test(arguments: [false, true])
    func lostSteerAcknowledgementReconcilesConsumptionOrRetriesOnlyOriginalID(consumed: Bool) async throws {
        let fixture = try await prepare()
        defer { fixture.model.resetSession() }
        await fixture.api.setDeliverSteers(consumed)
        await fixture.api.setFailAfterSteer(true)
        let item = try enqueue("lost acknowledgement", fixture)
        fixture.model.steerQueued(item.id)
        try await fixture.wait { fixture.model.steeringIds.isEmpty }
        if consumed {
            #expect(fixture.model.queuedMessages.isEmpty && fixture.model.steeredMessages.isEmpty)
            #expect(await fixture.api.steers.map(\.id) == [item.id])
        } else {
            #expect(fixture.model.isQueuePaused && fixture.model.queuedMessages == [item])
            #expect(fixture.model.canResumeQueue)
            await fixture.api.setFailAfterSteer(false)
            fixture.model.resumeQueue()
            try await fixture.wait { fixture.model.steeringIds.isEmpty && !fixture.model.steeredMessages.isEmpty }
            #expect(fixture.model.steeredMessages == [item])
            #expect(await fixture.api.steers.map(\.id) == [item.id, item.id])
            #expect(await fixture.api.steers.allSatisfy { $0.runId == "original" })
        }
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func heldSteerSelectionChangeReconcilesWithoutActivatingOrAdvancingConversation() async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        await fixture.api.setAfterSteer { await gate.wait() }
        let item = try enqueue("first conversation", fixture)
        let originalID = try #require(fixture.model.selectedId)
        fixture.model.steerQueued(item.id)
        await gate.untilEntered()
        let other = AskConversation(id: "other-conversation", title: "Other", revision: 1, updatedAt: Date(), messages: [])
        await fixture.api.seed(other)
        await fixture.model.select(other.id)
        fixture.model.draft.text = "other draft"
        await gate.release()
        try await fixture.wait { fixture.model.steeringIds.isEmpty }
        #expect(fixture.model.selectedId == other.id && fixture.model.draft.text == "other draft")
        #expect(fixture.model.sendQueue.isPaused(originalID))
        #expect(fixture.model.sendQueue.steeredMessages(originalID).map(\.id) == [item.id])
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func queueResumeCannotBypassCreditDeviceOrReceiptBlockers() async throws {
        let fixture = try await prepare()
        defer { fixture.model.resetSession() }
        let item = try enqueue("wait safely", fixture)
        try await publish("paused_credits", fixture)
        fixture.model.resumeQueue()
        #expect(fixture.model.queuedMessages == [item] && !fixture.model.canSteer && !fixture.model.canResumeQueue)
        var remote = try #require(fixture.model.selected)
        remote.revision += 1; remote.run?.status = "waiting_inference"; remote.run?.deviceId = "other"
        await fixture.api.seed(remote)
        try await fixture.model.accept(remote, route: #require(fixture.model.credentials()))
        fixture.model.stop(); fixture.model.resumeQueue()
        #expect(fixture.model.queuedMessages == [item] && !fixture.model.canSteer && !fixture.model.canResumeQueue)
        #expect(await fixture.api.cancellations.isEmpty)
        fixture.model.recoveryEntries[remote.id] = [.init(id: "unavailable")]
        fixture.model.queueDidSettle(remote.id)
        fixture.model.resumeQueue()
        #expect(fixture.model.isQueuePaused && fixture.model.queuePauseReason == L("ask.run.needsDecision"))
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test(arguments: ["remove", "clear"])
    func discardedQueuedSendReconcilesWithoutResending(_ action: String) async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        let item = try enqueue("discard after dispatch", fixture)
        await fixture.api.setBeforeSend { await gate.wait() }
        try await publish("completed", fixture)
        await gate.untilEntered()
        if action == "remove" { fixture.model.removeQueued(item.id) }
        else { fixture.model.clearQueue() }
        await gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages.isEmpty && fixture.model.steeredMessages.isEmpty)
        #expect(fixture.model.hasPendingSubmission)
        await fixture.api.setBeforeSend(nil)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty && !fixture.model.hasPendingSubmission }
        #expect(await fixture.api.sends.map(\.id) == [item.id])
        #expect(fixture.tools.folderAdmissions.isEmpty, "removed submissions cannot grant local folder authority")
    }

    @Test func malformedTerminalIdentityCannotAdvanceQueue() {
        var malformed = run("completed", id: "")
        #expect(AskQueueDisposition.resolve(run: malformed, recoveryBlocked: false, submitting: false,
            steering: false, pendingApproval: false, deviceID: "device", paused: false, hasItems: true) == .blocked(.recovery))
        malformed.id = "valid"; malformed.deviceId = ""
        #expect(AskQueueDisposition.resolve(run: malformed, recoveryBlocked: false, submitting: false,
            steering: false, pendingApproval: false, deviceID: "device", paused: false, hasItems: true) == .blocked(.recovery))
    }

    @Test(arguments: ["clear", "selection"])
    func heldQueuedModelPreflightRetainsOnlyOwnedIntent(_ action: String) async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        await fixture.api.setCloudModels([.init(id: "queued-model", name: "Fixture")])
        await fixture.api.setBeforeModels { await gate.wait() }
        fixture.model.draft.text = "held model validation"
        fixture.model.draft.modelRef = "cloud:queued-model"
        fixture.model.submitDraft()
        let item = try #require(fixture.model.queuedMessages.first)
        let originalID = try #require(fixture.model.selectedId)
        try await publish("completed", fixture)
        await gate.untilEntered()
        if action == "clear" { fixture.model.clearQueue() }
        else {
            let other = AskConversation(id: "different", title: "Other", revision: 1, updatedAt: Date(), messages: [])
            await fixture.api.seed(other); await fixture.model.select(other.id)
            fixture.model.draft.text = "other composer"
        }
        await gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        if action == "clear" { #expect(fixture.model.sendQueue.messages(originalID).isEmpty) }
        else {
            #expect(fixture.model.sendQueue.messages(originalID) == [item])
            #expect(fixture.model.sendQueue.isPaused(originalID) && fixture.model.draft.text == "other composer")
        }
    }

    @Test(arguments: ["retry", "remove", "replacement"])
    func uncertainQueuedSendCannotReplayRemovedIntentOrInterruptReplacement(_ action: String) async throws {
        let fixture = try await prepare()
        defer { fixture.model.resetSession() }
        let item = try enqueue("retry exact draft", fixture)
        await fixture.api.setFailSend(true)
        try await publish("completed", fixture)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.hasPendingSubmission && fixture.model.queuedMessages == [item] && fixture.model.isQueuePaused)
        if action == "remove" { fixture.model.removeQueued(item.id) }
        if action == "replacement" {
            var replacement = try #require(fixture.model.selected)
            replacement.messages.removeAll { $0.id == item.id }
            replacement.run = run("running", id: "replacement"); replacement.revision += 10
            await fixture.api.seed(replacement)
            try await fixture.model.accept(replacement, route: #require(fixture.model.credentials()))
        }
        await fixture.api.setFailSend(false)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        if action == "retry" {
            #expect(await fixture.api.sends.map(\.id) == [item.id])
            #expect(!fixture.model.hasPendingSubmission && fixture.model.queuedMessages.isEmpty)
        } else {
            #expect(await fixture.api.sends.isEmpty)
            #expect(fixture.model.hasPendingSubmission)
        }
    }

    @Test(arguments: ["completed", "failed", "cancelled"])
    func explicitResumeReconcilesUnconsumedOriginalTerminalBeforeSending(_ status: String) async throws {
        let fixture = try await prepare()
        defer { fixture.model.resetSession() }
        await fixture.api.setFailSteer(true)
        let item = try enqueue("terminal reconciliation", fixture)
        fixture.model.steerQueued(item.id)
        try await fixture.wait { fixture.model.steeringIds.isEmpty }
        let pendingView = NSHostingView(rootView: AskQueueBar(model: fixture.model, expanded: .constant(false)).frame(width: 640))
        pendingView.layoutSubtreeIfNeeded()
        #expect(pendingView.fittingSize.height > 20)
        fixture.model.stopSelectionObservation()
        var terminal = try #require(fixture.model.selected)
        terminal.run = run(status); terminal.revision += 10
        await fixture.api.seed(terminal)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.steeringIds.isEmpty && fixture.model.queuedMessages.isEmpty }
        #expect(await fixture.api.sends.map(\.id) == [item.id])
        #expect(fixture.model.steeredMessages.isEmpty)
    }

    @Test func wrongRunSteerSuccessRetainsIntentAndReportsOneReconciliationAction() async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        await fixture.api.setBeforeSteer { await gate.wait() }
        let item = try enqueue("captured original run", fixture)
        fixture.model.steerQueued(item.id)
        await gate.untilEntered()
        try await publish("running", fixture, runID: "replacement")
        await gate.release()
        try await fixture.wait { fixture.model.steeringIds.isEmpty }
        #expect(fixture.model.isQueuePaused && fixture.model.queuedMessages == [item])
        #expect(fixture.model.error == L("ask.queue.reconcile"))
        #expect(await fixture.api.sends.isEmpty)
        fixture.model.clearQueue()
        try await publish("completed", fixture, revision: 20, runID: "replacement")
        let selectedID = try #require(fixture.model.selectedId)
        #expect(fixture.model.sendQueue.canEnqueue(selectedID))
    }

    @Test(arguments: [false, true])
    func deletingDuringHeldQueuedSendCancelsAndDrainsLocalOwnership(accepted: Bool) async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        _ = try enqueue("delete while sending", fixture)
        let id = try #require(fixture.model.selectedId)
        if accepted { await fixture.api.setAfterSend { await gate.wait() } }
        else { await fixture.api.setBeforeSend { await gate.wait() } }
        try await publish("completed", fixture)
        await gate.untilEntered()
        if accepted {
            let confirmed = try await fixture.api.conversation(id: id, token: "token")
            try await fixture.model.accept(confirmed, route: #require(fixture.model.credentials()))
            #expect(!fixture.model.hasPendingSubmission)
        }
        async let deletion: Void = fixture.model.delete(id)
        await gate.untilCancelled()
        await gate.release()
        await deletion
        #expect(await fixture.api.deletes == [id])
        #expect(fixture.model.selected == nil && fixture.model.sendQueue.messages(id).isEmpty)
        #expect(!fixture.model.sendQueue.isPaused(id))
        #expect(fixture.tools.folderAdmissions.isEmpty)
    }

    @Test(arguments: [false, true])
    func authenticatedQueuedAcceptancePreservesLocalOwnershipAndIgnoresLateTransportError(stop: Bool) async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        let item = try enqueue("authoritative acceptance", fixture)
        let id = try #require(fixture.model.selectedId)
        await fixture.api.setAfterSend { await gate.wait() }
        try await publish("completed", fixture)
        await gate.untilEntered()
        let authenticated = try await fixture.api.conversation(id: id, token: "token")
        try await fixture.model.accept(authenticated, route: #require(fixture.model.credentials()))
        #expect(!fixture.model.hasPendingSubmission && fixture.model.queuedMessages.isEmpty)
        #expect(fixture.model.busyIds.contains(id), "server acceptance does not revoke local task ownership")
        if stop {
            fixture.model.stop()
            await gate.untilCancelled()
        } else { await fixture.api.setFailAfterSend(true) }
        await gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        if !stop { #expect(fixture.model.error == nil) }
        fixture.model.resumeQueue()
        #expect(await fixture.api.sends.map(\.id) == [item.id])
        #expect(fixture.model.queuedMessages.isEmpty)
    }

    @Test func queuedFolderAdmissionPrecedesRetirementOfThePreviousRun() async throws {
        let fixture = try await prepare()
        defer { fixture.model.resetSession() }
        fixture.model.draft.text = "use my selected folder"
        fixture.model.draft.attachments = [.init(kind: .folder, name: "Fixture folder", path: "/fixture-folder")]
        fixture.model.submitDraft()
        let item = try #require(fixture.model.queuedMessages.first)
        try await publish("completed", fixture)
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.queuedMessages.isEmpty }
        let staged = try #require(fixture.tools.folderEvents.firstIndex(of: "stage"))
        let admission = try #require(fixture.tools.folderEvents.firstIndex(of: "admit:" + item.id))
        let revoked = try #require(fixture.tools.folderEvents.indices.first {
            $0 > staged && fixture.tools.folderEvents[$0].hasPrefix("revoke:")
        })
        #expect(staged < admission && admission < revoked)
        #expect(fixture.tools.folderAdmissions.map { $0.0 } == [item.id])
    }

    @Test func accountChangeBeforeQueuedResponseCannotRestoreOrAdvanceOldIntent() async throws {
        let fixture = try await prepare()
        let gate = QueueGate()
        defer { fixture.model.resetSession() }
        let item = try enqueue("previous account only", fixture)
        await fixture.api.setBeforeSend { await gate.wait() }
        try await publish("completed", fixture)
        await gate.untilEntered()
        fixture.sessionState.owner = "different-account"
        await gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages.isEmpty)
        #expect(await fixture.api.sends.map(\.id) == [item.id])
        fixture.model.queueDidSettle("queue-ownership")
        #expect(fixture.model.queuedMessages.isEmpty)
        #expect(fixture.tools.folderAdmissions.isEmpty)
    }

    @Test func unknownAndRemoteWaitPresentationOverrideUnwindingWork() {
        let unknown = run("future")
        #expect(AskRunPhase.resolve(run: unknown, busy: true, pendingApproval: true, recovery: nil) == .needsDecision(step: 2))
        var remote = run("waiting_inference"); remote.deviceId = "other"
        let recovery = AskRecoveryPresentation(run: remote, entries: [], deviceId: "device", local: false)
        let phase = AskRunPhase.resolve(run: remote, busy: true, pendingApproval: false, recovery: recovery)
        #expect(phase == .waitingDevice(step: 2))
        #expect(phase?.tone == .attention && phase?.isWorking == false && phase?.offersStop == false)
        #expect(phase?.step == 2 && phase?.summary == L("ask.recovery.otherDevice"))
        remote.status = "running"
        #expect(AskRunPhase.resolve(run: remote, busy: true, pendingApproval: false, recovery: recovery) == .working(step: 2))
    }
}


extension AskQueueOwnershipTests {
    @Test(arguments: [false, true], ["usage", "recovery", "budget", "cache"])
    func independentClocksCannotConfirmHeldQueuedSend(local: Bool, clock: String) async throws {
        let cacheGate = QueueGate()
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let base = try AskConversationCache(url: cacheRoot.appendingPathComponent("cache.sqlite"))
        let cache = GatedConversationCache(base: base) { value in
            if clock == "cache", value.usage?.version == 1 { await cacheGate.wait() }
        }
        let fixture = try await prepare(local: local, cacheOverride: cache)
        defer { fixture.model.resetSession() }
        let api = local ? fixture.localAPI : fixture.api
        let item = try enqueue("Exact draft, selection and ID must survive", fixture)
        let next = try enqueue("No automatic fallback", fixture)
        fixture.model.draft.text = "Keep current composer"
        let sendGate = QueueGate()
        await api.setBeforeSend { await sendGate.wait() }
        try await publish("completed", fixture)
        await sendGate.untilEntered()
        let id = try #require(fixture.model.selectedId)
        let route = try #require(fixture.model.credentials(for: id))
        var incoming = try await api.conversation(id: id, token: route.token)
        #expect(!incoming.messages.contains { $0.id == item.id })
        #expect(fixture.model.selected?.messages.contains { $0.id == item.id } == true)
        let revision = incoming.revision
        switch clock {
        case "recovery": incoming.run?.recovery = .init(state: "completed", sequence: 1)
        case "budget":
            incoming.run?.budget = .init(version: 1, limits: .init(), occupied: .init(), actual: .init(),
                pending: 1, deadline: Date().addingTimeInterval(60), metering: "fixture")
        default:
            incoming.usage = .init(version: 1, since: Date(), historicalGap: false,
                total: .init(calls: 1, pending: 1), runs: [:])
        }
        #expect(incoming.revision == revision)
        let update = Task { try await fixture.model.accept(incoming, route: route) }
        if clock == "cache" {
            await cacheGate.untilEntered()
            // The cache write contains the optimistic message; it must never become evidence.
            #expect(fixture.model.hasPendingSubmission)
            await cacheGate.release()
        }
        try await update.value
        #expect(fixture.model.hasPendingSubmission)
        #expect(fixture.model.selected?.messages.contains { $0.id == item.id } == true)
        if clock == "usage" || clock == "cache" { #expect(fixture.model.selected?.usage?.version == 1) }
        if clock == "budget" { #expect(fixture.model.selected?.run?.budget?.version == 1) }
        // Terminal recovery metadata follows the existing freshness policy and cannot resurrect content.
        if clock == "recovery" { #expect(fixture.model.selected?.run?.status == "completed") }
        await api.setFailSend(true)
        await sendGate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages == [item, next])
        #expect(fixture.model.isQueuePaused && fixture.model.hasPendingSubmission)
        #expect(fixture.model.draft.text == "Keep current composer")
        #expect(await api.sends.map(\.id) == [item.id])
        #expect(try await api.conversation(id: id, token: route.token).messages.isEmpty)
        // Another failed explicit retry must pause again and retain both exact drafts.
        await api.setBeforeSend(nil)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.isQueuePaused && fixture.model.queuedMessages == [item, next])
        // Retry reuses the sole pending request; a successful acknowledgement releases FIFO once.
        await api.setFailSend(false)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.queuedMessages.isEmpty }
        #expect(await api.sends.map(\.id) == [item.id, item.id, next.id])
        #expect(!fixture.model.hasPendingSubmission)
    }
}


extension AskQueueOwnershipTests {
    @Test func authenticatedAcceptanceSurvivesNewerDisplayDuringCacheWrite() async throws {
        let cacheGate = QueueGate(), sendGate = QueueGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let cache = GatedConversationCache(base: base) { value in
            if value.usage?.version == 1 { await cacheGate.wait() }
        }
        let fixture = try await prepare(cacheOverride: cache)
        defer { fixture.model.resetSession() }
        let item = try enqueue("Actual acknowledgement across suspension", fixture)
        await fixture.api.setAfterSend { await sendGate.wait() }
        try await publish("completed", fixture)
        await sendGate.untilEntered()
        let id = try #require(fixture.model.selectedId)
        let route = try #require(fixture.model.credentials())
        var accepted = try await fixture.api.conversation(id: id, token: route.token)
        #expect(accepted.messages.contains { $0.id == item.id })
        accepted.usage = .init(version: 1, since: Date(), historicalGap: false,
            total: .init(calls: 1, pending: 1), runs: [:])
        let confirmation = Task { try await fixture.model.accept(accepted, route: route) }
        await cacheGate.untilEntered()
        var newerClock = accepted
        newerClock.messages = []
        newerClock.usage?.version = 2
        try await fixture.model.accept(newerClock, route: route)
        #expect(fixture.model.hasPendingSubmission)
        await cacheGate.release()
        try await confirmation.value
        #expect(!fixture.model.hasPendingSubmission)
        #expect(fixture.model.selected?.usage?.version == 2)
        await fixture.api.setFailAfterSend(true)
        await sendGate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages.isEmpty && fixture.model.error == nil)
        fixture.model.resumeQueue()
        #expect(await fixture.api.sends.map(\.id) == [item.id])
    }
}


extension AskQueueOwnershipTests {
    @Test(arguments: [false, true])
    func admittedRecoveryClockCannotConfirmOptimisticIntentOrReplayIntoReplacement(local: Bool) async throws {
        let fixture = try await prepare(local: local)
        defer { fixture.model.resetSession() }
        let api = local ? fixture.localAPI : fixture.api
        let item = try enqueue("Retain original intent through recovery", fixture)
        let gate = QueueGate()
        await api.setBeforeSend { await gate.wait() }
        try await publish("completed", fixture)
        await gate.untilEntered()
        // Build evidence from API state, never the optimistic selected transcript.
        let id = try #require(fixture.model.selectedId)
        let route = try #require(fixture.model.credentials())
        var recovery = try await api.conversation(id: id, token: route.token)
        #expect(!recovery.messages.contains { $0.id == item.id })
        recovery.run = run("running", id: "replacement"); recovery.revision = 11
        await api.seed(recovery)
        try await fixture.model.accept(recovery, route: route)
        recovery.run?.recovery = .init(state: "running", sequence: 1)
        try await fixture.model.accept(recovery, route: route)
        #expect(fixture.model.selected?.run?.recovery?.sequence == 1)
        #expect(fixture.model.hasPendingSubmission)
        await api.setFailSend(true)
        await gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages == [item] && fixture.model.isQueuePaused)
        await api.setBeforeSend(nil)
        await api.setFailSend(false)
        fixture.model.resumeQueue()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await api.sends.map(\.id) == [item.id])
        #expect(fixture.model.queuedMessages == [item] && fixture.model.isQueuePaused)
    }
}
