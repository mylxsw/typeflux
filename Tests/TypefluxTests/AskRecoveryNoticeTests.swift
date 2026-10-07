import Foundation
import Testing
@testable import Typeflux

@Suite("Ask recovery notice visibility")
struct AskRecoveryNoticePresentationTests {
    @Test(arguments: ["completed", "failed", "cancelled", "running"])
    func `ordinary run status does not need a recovery notice`(status: String) {
        var value = AskRecoveryFixture.conversation()
        value.run?.status = status
        value.run?.pending = []
        value.run?.recovery = .init(state: status, sequence: 1)
        let presentation = AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: false)
        #expect(!presentation.isVisible)
        #expect(!presentation.canContinue)
        #expect(!presentation.unknown)
        #expect(presentation.savedReceipts == 0)
    }

    @Test func `history without a run does not need a recovery notice`() {
        let presentation = AskRecoveryPresentation(run: nil, entries: [], deviceId: "device", local: false)
        #expect(!presentation.isVisible)
        #expect(!presentation.canContinue)
        #expect(presentation.titleKey == "ask.recovery.finished")
        #expect(presentation.bodyKey == "ask.recovery.finishedBody")
        #expect(!presentation.canEnd)
    }

    @Test(arguments: ["waiting_tool", "completed"])
    func `unsynced results on another device explain where to continue`(status: String) {
        var value = AskRecoveryFixture.conversation()
        value.run?.status = status
        let audit = AskRecoveryFixture.audit(value)
        let entry = AskExecutionEntry(id: audit.identity.key, audit: audit, receipt: AskRecoveryFixture.receipt(value))
        let presentation = AskRecoveryPresentation(
            run: value.run,
            entries: [entry],
            deviceId: "replacement",
            local: false
        )
        #expect(presentation.isVisible && !presentation.canContinue)
        #expect(presentation.titleKey == "ask.recovery.otherDevice")
        #expect(!presentation.canEnd)
        #expect(presentation.bodyKey == "ask.recovery.binding")
    }

    @Test(arguments: ["waiting_tool", "waiting_inference"])
    func `only this device waiting for work offers to continue`(status: String) {
        var value = AskRecoveryFixture.conversation()
        value.run?.status = status
        let local = AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: false)
        let remote = AskRecoveryPresentation(run: value.run, entries: [], deviceId: "other-device", local: false)
        #expect(local.isVisible && local.canContinue)
        #expect(local.canEnd && !remote.canEnd)
        #expect(!local.unknown && local.savedReceipts == 0)
        #expect(!remote.isVisible && !remote.canContinue)
    }

    @Test(arguments: [false, true])
    func `confirmed results stay silent but unsynced results need attention`(inference: Bool) {
        var value = AskRecoveryFixture.conversation(model: inference)
        value.run?.status = "completed"
        let receipt = AskRecoveryFixture.receipt(value, model: inference)
        var audit = AskRecoveryFixture.audit(value, model: inference)
        let saved = AskExecutionEntry(id: audit.identity.key, audit: audit, receipt: receipt)
        let pending = AskRecoveryPresentation(run: value.run, entries: [saved], deviceId: "device", local: false)
        #expect(pending.isVisible && !pending.canContinue)
        #expect(!pending.unknown && pending.savedReceipts == 1)
        audit.record(.acknowledged)
        let confirmed = AskExecutionEntry(id: audit.identity.key, audit: audit, receipt: receipt)
        let settled = AskRecoveryPresentation(run: value.run, entries: [confirmed], deviceId: "device", local: false)
        #expect(!settled.isVisible && !settled.canContinue)
        #expect(!settled.unknown && settled.savedReceipts == 0)
    }

    @Test func `unknown current outcome and unreadable legacy record still need attention`() {
        var value = AskRecoveryFixture.conversation()
        value.run?.status = "cancelled"
        let audit = AskRecoveryFixture.audit(value)
        for entry in [AskExecutionEntry(id: audit.identity.key, audit: audit), .init(id: "legacy")] {
            let presentation = AskRecoveryPresentation(
                run: value.run,
                entries: [entry],
                deviceId: "device",
                local: false
            )
            #expect(presentation.isVisible && presentation.unknown)
        }
    }

    @Test func `uncertain server outcome remains visible without local records`() {
        var value = AskRecoveryFixture.conversation()
        value.run?.recovery = .init(state: "unknown_outcome", sequence: 1)
        let presentation = AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: false)
        #expect(presentation.isVisible && presentation.unknown)
        #expect(!presentation.canContinue)
    }

    @Test(arguments: ["completed", "failed", "cancelled", "waiting_tool"])
    func `delivered uncertain attempt only interrupts an active run`(status: String) {
        var value = AskRecoveryFixture.conversation()
        value.run?.status = status
        var audit = AskRecoveryFixture.audit(value)
        audit.record(.acknowledged)
        let receipt = AskExecutionReceipt.tool(.init(
            runId: value.run!.id, deviceId: "device", toolCallId: "call",
            content: "Screenshot failed before a later successful attempt", isError: true
        ))
        let entry = AskExecutionEntry(id: audit.identity.key, audit: audit, receipt: receipt)
        let presentation = AskRecoveryPresentation(run: value.run, entries: [entry], deviceId: "device", local: false)
        #expect(entry.unknown)
        #expect(presentation.isVisible == (status == "waiting_tool"))
        value.run?.recovery = .init(state: "unknown_outcome", sequence: 2)
        #expect(AskRecoveryPresentation(run: value.run, entries: [entry], deviceId: "device", local: false).unknown)
    }

    @Test func `unfinished current execution cannot offer to continue before inspection or sync`() {
        let value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        let unknown = AskExecutionEntry(id: audit.identity.key, audit: audit)
        let saved = AskExecutionEntry(id: audit.identity.key, audit: audit, receipt: AskRecoveryFixture.receipt(value))
        for entry in [unknown, saved] {
            let presentation = AskRecoveryPresentation(
                run: value.run,
                entries: [entry],
                deviceId: "device",
                local: false
            )
            #expect(presentation.isVisible && !presentation.canContinue)
        }
    }

    @Test func `old run entries do not change the current run notice`() {
        var value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        let unknown = AskExecutionEntry(id: audit.identity.key, audit: audit)
        let saved = AskExecutionEntry(id: audit.identity.key, audit: audit, receipt: AskRecoveryFixture.receipt(value))
        value.run?.id = "next-run"
        value.run?.status = "completed"
        for entry in [unknown, saved] {
            let presentation = AskRecoveryPresentation(
                run: value.run,
                entries: [entry],
                deviceId: "device",
                local: false
            )
            #expect(!presentation.isVisible && !presentation.unknown)
            #expect(presentation.savedReceipts == 0)
        }
    }
}

@Suite("Ask recovery notice interactions", .serialized)
@MainActor
struct AskRecoveryNoticeInteractionTests {
    @Test func `completed retry with delivered failure stays quiet after reopening`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        let receipt = AskExecutionReceipt.tool(.init(
            runId: value.run!.id, deviceId: "device", toolCallId: "call", content: "Failed first attempt", isError: true
        ))
        try await fixture.cache.saveReceipt(receipt, identity: audit.identity, owner: "owner")
        try await fixture.cache.recordExecution(id: audit.identity.key, event: .acknowledged, owner: "owner")
        value.run?.status = "completed"
        value.run?.pending = []
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(!fixture.model.hasRecoveryNotice)
        #expect(!fixture.model.recoveryBlocksResume(value))
        #expect(fixture.model.selectedRecoveryEntries.first?.unknown == true)
        #expect(fixture.model.selectedRecoveryEntries.first?.acknowledged == true)
        #expect(fixture.tools.executions == 0)
    }

    @Test func `successful tool completion and reopening stay quiet without removing receipts`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        fixture.model.launcherDraft.text = "Read this page"
        fixture.model.setPermissionMode(.strict, launcher: true)
        fixture.model.submitLauncher()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        let id = try #require(fixture.model.selectedId)
        fixture.model.approve(conversationId: id, allowed: true)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.selected?.run?.status == "completed")
        #expect(!fixture.model.hasRecoveryNotice)
        #expect(fixture.tools.executions == 1)
        #expect(await fixture.api.results.count == 1)
        let originalEntries = try await fixture.cache.executions(conversationId: id, owner: "owner")
        let receipt = try #require(originalEntries.first)
        #expect(originalEntries.count == 1 && receipt.acknowledged)
        #expect(receipt.receipt?.status == "ok")
        fixture.model.resetSession()

        let reopenedCache = try AskConversationCache(url: fixture.root.appendingPathComponent("cache.sqlite"))
        let reopened = AskConversationModel(
            api: fixture.api,
            cache: reopenedCache,
            tools: fixture.tools,
            capture: fixture.capture,
            deviceId: "device",
            modelLibrary: fixture.model.modelLibrary,
            session: { (fixture.sessionState.owner, "token") }
        )
        defer { reopened.resetSession() }
        await reopened.select(id)
        #expect(!reopened.hasRecoveryNotice && !reopened.canRetransmitReceipts)
        #expect(reopened.selectedRecoveryEntries == originalEntries)
        await reopened.retransmitSavedReceipts()
        #expect(fixture.tools.executions == 1)
        #expect(await fixture.api.results.count == 1)
        #expect(try await reopenedCache.execution(id: receipt.id, owner: "owner") == receipt)
    }

    @Test(arguments: ["completed", "failed", "cancelled", "no-run"])
    func `reopening ordinary history does not imply an interruption`(status: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        if status == "no-run" {
            value.run = nil
        } else {
            value.run?.status = status
            value.run?.pending = []
            value.run?.recovery = .init(state: status, sequence: 3)
        }
        try await fixture.cache.save(value, owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(!fixture.model.hasRecoveryNotice)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.isEmpty)
    }

    @Test func `a new completed run ignores old uncertainty while keeping its evidence`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        value.run?.id = "next-run"
        value.run?.status = "completed"
        value.run?.pending = []
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(!fixture.model.hasRecoveryNotice)
        #expect(!fixture.model.recoveryBlocksResume(value))
        #expect(fixture.model.selectedRecoveryEntries.first?.unknown == true)
        #expect(try await fixture.cache.execution(id: audit.identity.key, owner: "owner")?.audit == audit)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.isEmpty)
    }

    @Test func `old unsynced receipt does not replace continue with sync for a new task`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        try await fixture.cache.saveReceipt(AskRecoveryFixture.receipt(value), identity: audit.identity, owner: "owner")
        value.run?.id = "next-run"
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(fixture.model.hasRecoveryNotice && fixture.model.recoveryPresentation.canContinue)
        #expect(!fixture.model.canRetransmitReceipts)
        #expect(!fixture.model.recoveryBlocksResume(value))
        #expect(fixture.model.recoveryPresentation.savedReceipts == 0)
        #expect(fixture.model.selectedRecoveryEntries.first?.acknowledged == false)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.isEmpty)
    }
}
