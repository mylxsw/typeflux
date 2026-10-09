import Foundation
import Testing
@testable import Typeflux

@Suite("Ask credit pauses", .exclusiveUIState)
@MainActor
struct AskCreditPauseTests {
    private func pausedRun(pending: [AskToolCall] = []) -> AskRun {
        var run = AskRun(id: "run", deviceId: "device", status: "paused_credits", steps: 2, updatedAt: Date(),
                         tools: [], pending: pending)
        run.stopReason = "credits_exhausted"
        run.creditsPausedAt = Date()
        return run
    }

    private func paused(_ id: String = "paused", pending: [AskToolCall] = []) -> AskConversation {
        AskConversation(id: id, title: "Task", revision: 3, updatedAt: Date(), messages: [
            .init(id: "user", role: "user", text: "Summarize", createdAt: Date(), runId: "run")
        ], run: pausedRun(pending: pending))
    }

    private let subscription = BillingSubscriptionSnapshot(
        planCode: "pro", status: "active", currentPeriodStart: nil, currentPeriodEnd: nil,
        cancelAtPeriodEnd: false, entitled: true, billingEnabled: true
    )

    // MARK: Run state

    @Test func pausedRunIsAKnownActiveCheckpoint() throws {
        let run = pausedRun()
        #expect(run.isActive)
        #expect(run.isPausedForCredits)
        #expect(!run.needsRecoveryInspection)
        #expect(!AskRunRecovery(state: "paused_credits", sequence: 4).blocksExecution)
        let json = #"{"id":"run","device_id":"device","status":"paused_credits","steps":1,"updated_at":"2026-10-08T10:00:00Z","tools":[],"pending":[],"stop_reason":"credits_exhausted","credits_paused_at":"2026-10-08T10:00:00Z"}"#
        let decoded = try AskCoding.decoder().decode(AskRun.self, from: Data(json.utf8))
        #expect(decoded.creditsPausedAt != nil)
        #expect(decoded.isPausedForCredits)
    }

    @Test func pauseTakesPriorityOverUnknownRecovery() {
        let run = pausedRun()
        let recovery = AskRecoveryPresentation(run: run, entries: [], deviceId: "device", local: false)
        #expect(!recovery.unknown)
        #expect(!recovery.isVisible)
        #expect(AskRunPhase.resolve(run: run, busy: false, pendingApproval: false, recovery: recovery)
            == .pausedCredits(step: 2))
        // While `resume` drives the run, it reads as working again.
        #expect(AskRunPhase.resolve(run: run, busy: true, pendingApproval: false, recovery: recovery)
            == .working(step: 2))
        let phase = AskRunPhase.pausedCredits(step: 2)
        #expect(phase.offersStop)
        #expect(!phase.isWorking)
        #expect(phase.step == 2)
        #expect(phase.tone == .attention)
        #expect(phase.summary == L("ask.run.pausedCredits"))
    }

    // MARK: Presentation

    @Test func exhaustedBalanceOffersBuyingAndUpgrading() throws {
        let credits = CloudCreditSummary(limit: 300_000, used: 300_000, remaining: 0, unlimited: false,
                                         totalRemaining: 0, addon: .init(balance: 0, usedThisPeriod: 0, remaining: 0))
        let card = try #require(AskCreditPausePresentation(run: pausedRun(), busy: false, credits: credits, details: nil,
                                                           subscription: subscription, usagePeriodEnd: nil))
        #expect(card.state == .exhausted)
        #expect(card.monthlyRemaining == 0)
        #expect(card.addonRemaining == 0)
        #expect(card.primary == .buyCredits)
        #expect(card.secondary == .upgradePlan)
        #expect(card.titleKey == "ask.credits.exhausted.title")
        #expect(card.bodyKey == "ask.credits.exhausted.body")
        #expect(!card.confirmedByServer)
    }

    @Test func refreshedBalanceTurnsTheCardIntoContinue() throws {
        let credits = CloudCreditSummary(limit: 300_000, used: 300_000, remaining: 0, unlimited: false,
                                         totalRemaining: 220_000, addon: .init(balance: 220_000, usedThisPeriod: 0,
                                                                               remaining: 220_000))
        let card = try #require(AskCreditPausePresentation(run: pausedRun(), busy: false, credits: credits, details: nil,
                                                           subscription: subscription, usagePeriodEnd: nil))
        #expect(card.state == .available)
        #expect(card.addonRemaining == 220_000)
        #expect(card.primary == .continueRun)
        #expect(card.secondary == nil)
        #expect(card.titleKey == "ask.credits.available.title")
        #expect(card.bodyKey == "ask.credits.available.body")
    }

    @Test func resumeRejectionWinsUntilTheBalanceRefreshes() throws {
        let stale = CloudCreditSummary(limit: 100, used: 10, remaining: 90, unlimited: false)
        let details = CloudCreditsExhaustedDetails(monthlyRemaining: 0, addonRemaining: 0,
                                                   periodEnd: "2026-11-01T00:00:00Z", purchasable: true)
        let card = try #require(AskCreditPausePresentation(run: pausedRun(), busy: false, credits: stale, details: details,
                                                           subscription: subscription, usagePeriodEnd: nil))
        #expect(card.state == .exhausted)
        #expect(card.confirmedByServer)
        #expect(card.monthlyRemaining == 0)
        #expect(card.bodyKey == "ask.credits.exhausted.stillBody")
        #expect(card.periodEnd != nil)
    }

    @Test func withoutBillingTheCardOnlyExplainsTheReset() throws {
        let free = BillingSubscriptionSnapshot.none
        let credits = CloudCreditSummary(limit: 100, used: 100, remaining: 0, unlimited: false)
        let dated = try #require(AskCreditPausePresentation(
            run: pausedRun(), busy: false, credits: credits, details: nil, subscription: free,
            usagePeriodEnd: "2026-11-01T00:00:00Z"
        ))
        #expect(dated.primary == nil && dated.secondary == nil)
        #expect(dated.bodyKey == "ask.credits.exhausted.waitUntilBody")
        let undated = try #require(AskCreditPausePresentation(
            run: pausedRun(), busy: false, credits: nil, details: .init(purchasable: false), subscription: subscription,
            usagePeriodEnd: nil
        ))
        #expect(undated.primary == nil)
        #expect(undated.bodyKey == "ask.credits.exhausted.waitBody")
    }

    @Test func unknownOrUnlimitedBalancesShowNoColumns() throws {
        let unknown = try #require(AskCreditPausePresentation(run: pausedRun(), busy: false, credits: nil, details: nil,
                                                              subscription: subscription, usagePeriodEnd: nil))
        #expect(unknown.state == .exhausted)
        #expect(unknown.monthlyRemaining == nil && unknown.addonRemaining == nil)
        let unlimited = try #require(AskCreditPausePresentation(
            run: pausedRun(), busy: false, credits: .init(limit: -1, used: 5, remaining: -1, unlimited: true), details: nil,
            subscription: subscription, usagePeriodEnd: nil
        ))
        #expect(unlimited.state == .available)
        #expect(unlimited.monthlyRemaining == nil)
    }

    @Test func cardOnlyAppearsForAnIdlePausedRun() {
        var running = pausedRun(); running.status = "running"
        #expect(AskCreditPausePresentation(run: running, busy: false, credits: nil, details: nil,
                                           subscription: subscription, usagePeriodEnd: nil) == nil)
        #expect(AskCreditPausePresentation(run: pausedRun(), busy: true, credits: nil, details: nil,
                                           subscription: subscription, usagePeriodEnd: nil) == nil)
        #expect(AskCreditPausePresentation(run: nil, busy: false, credits: nil, details: nil,
                                           subscription: subscription, usagePeriodEnd: nil) == nil)
    }

    @Test func actionsHaveTitlesAndSymbols() {
        let actions: [AskCreditPausePresentation.Action] = [.buyCredits, .upgradePlan, .continueRun]
        #expect(actions.map(AskCreditPausePresentation.titleKey)
            == ["ask.credits.buy", "ask.credits.upgrade", "ask.credits.continue"])
        #expect(Set(actions.map(AskCreditPausePresentation.symbol)).count == 3)
    }

    // MARK: Conversation model

    @Test func drivingStopsAtAPauseWithoutRunningPendingTools() async throws {
        let f = try AskTestFixture()
        let call = AskToolCall(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        await f.api.seed(paused(pending: [call]))
        await f.model.select("paused")
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.isEmpty)
        #expect(await f.api.resumes.isEmpty)
        #expect(!f.model.hasRecoveryNotice)
        #expect(f.model.runPhase == .pausedCredits(step: 2))
    }

    @Test func continueResumesThePinnedRunAndFinishesIt() async throws {
        let f = try AskTestFixture()
        await f.api.seed(paused())
        await f.model.select("paused")
        f.model.creditPauseDetails["paused"] = .init()
        f.model.resumeCreditPause()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        #expect(await f.api.resumes == ["run"])
        #expect(f.model.creditPauseDetails["paused"] == nil)
        #expect(f.model.selected?.messages.last?.text == "Resumed answer.")
        #expect(f.model.error == nil)
    }

    @Test func continueHandsAPendingToolBackToThisMac() async throws {
        let f = try AskTestFixture()
        let call = AskToolCall(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        await f.api.seed(paused(pending: [call]))
        await f.model.select("paused")
        f.model.resumeCreditPause()
        try await f.wait { f.model.pendingApprovals["paused"] != nil || f.model.busyIds.isEmpty }
        #expect(await f.api.resumes == ["run"])
        #expect(f.model.selected?.run?.isPausedForCredits == false)
        if !f.model.busyIds.isEmpty {
            f.model.stop()
            try await f.wait { f.model.busyIds.isEmpty }
        }
    }

    @Test func stillEmptyBalanceKeepsThePauseAndRefreshesTheAccount() async throws {
        let f = try AskTestFixture()
        await f.api.seed(paused())
        await f.model.select("paused")
        let details = CloudCreditsExhaustedDetails(monthlyRemaining: 0, addonRemaining: 0, periodEnd: nil, purchasable: true)
        await f.api.setResumeError(CloudCreditsExhaustedError(details: details))
        var refreshes = 0
        f.model.onCreditsExhausted = { refreshes += 1 }
        f.model.resumeCreditPause()
        try await f.wait { f.model.busyIds.isEmpty && f.model.creditPauseDetails["paused"] != nil }
        #expect(f.model.creditPauseDetails["paused"] == details)
        #expect(refreshes == 1)
        #expect(f.model.error == nil)
        #expect(f.model.selected?.run?.isPausedForCredits == true)
        f.model.creditBalanceDidChange()
        #expect(f.model.creditPauseDetails.isEmpty)
    }

    @Test func rejectionWithoutDetailsStillRecordsTheShortfall() async throws {
        let f = try AskTestFixture()
        await f.api.seed(paused())
        await f.model.select("paused")
        await f.api.setResumeError(CloudCreditsExhaustedError(details: nil))
        f.model.resumeCreditPause()
        try await f.wait { f.model.busyIds.isEmpty && f.model.creditPauseDetails["paused"] != nil }
        #expect(f.model.creditPauseDetails["paused"] == CloudCreditsExhaustedDetails())
    }

    @Test func otherResumeFailuresAreReported() async throws {
        let f = try AskTestFixture()
        await f.api.seed(paused())
        await f.model.select("paused")
        await f.api.setResumeError(AskLocalError.message("Offline"))
        f.model.resumeCreditPause()
        try await f.wait { f.model.busyIds.isEmpty && f.model.error != nil }
        #expect(f.model.error == "Offline")
        #expect(f.model.creditPauseDetails.isEmpty)
    }

    @Test func continueIgnoresRunsThatAreNotPaused() async throws {
        let f = try AskTestFixture()
        var value = paused()
        value.run?.status = "completed"
        await f.api.seed(value)
        await f.model.select("paused")
        f.model.resumeCreditPause()
        #expect(f.model.busyIds.isEmpty)
        #expect(await f.api.resumes.isEmpty)
    }

    @Test func localConversationsHaveNothingToResume() async throws {
        let api = AskTestAPI()
        let value = paused("local")
        await api.seed(value)
        let routed = AskRoutedAPI(cloud: AskTestAPI(), local: api)
        // The default implementation re-reads the conversation instead of calling a server.
        struct Bare: AskAPI {
            let inner: AskTestAPI
            func list(token: String, offset: Int) async throws -> [AskConversationSummary] { [] }
            func conversation(id: String, token: String) async throws -> AskConversation {
                try await inner.conversation(id: id, token: token)
            }
            func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
                throw AskLocalError.message("unused")
            }
            func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
                throw AskLocalError.message("unused")
            }
            func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
                throw AskLocalError.message("unused")
            }
            func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?,
                       token: String) async throws -> AskConversation { throw AskLocalError.message("unused") }
            func regenerate(conversationId: String, request: AskRegenerateRequest,
                            token: String) async throws -> AskConversation { throw AskLocalError.message("unused") }
            func delete(conversationId: String, token: String) async throws {}
        }
        let bare = Bare(inner: api)
        #expect(try await bare.resume(conversationId: "local", runId: "run", token: "").run?.isPausedForCredits == true)
        #expect(try await routed.resume(conversationId: "local", runId: "run", token: "").messages.last?.text == "Resumed answer.")
    }
}
