import Foundation
import Testing
@testable import Typeflux

struct AskRecoveryDetailsTests {
    @Test func `missing pause reason is not guessed from assistant narration`() {
        var value = AskRecoveryFixture.conversation()
        value.run?.steps = 67
        value.messages.append(.init(
            id: "narration",
            role: "assistant",
            text: "Maybe a network timeout caused this.",
            createdAt: .now
        ))
        let details = AskRecoveryDetails(conversation: value, entries: [], deviceId: "device")
        #expect(details.reason == .unrecorded)
        #expect(details.savedResults == 0 && details.unconfirmedResults == 0)
        #expect(details.step == 67 && details.pendingKind == "browser")
    }

    @Test func `details count only bound current results and label the plan as recorded progress`() {
        var value = AskRecoveryFixture.conversation()
        value.run?.plan = [
            .init(step: "Inspect", status: "completed"),
            .init(step: "Fix selectors", status: "in_progress"),
            .init(step: "Verify", status: "pending")
        ]
        var acknowledged = AskRecoveryFixture.audit(value)
        acknowledged.record(.acknowledged)
        var old = acknowledged
        old.identity.runId = "older"
        let entries = [
            AskExecutionEntry(id: "saved", audit: acknowledged, receipt: AskRecoveryFixture.receipt(value)),
            .init(id: "missing", audit: AskRecoveryFixture.audit(value)),
            .init(id: "old", audit: old),
            .init(id: "deleted", audit: acknowledged, receipt: AskRecoveryFixture.receipt(value), deleted: true)
        ]
        let details = AskRecoveryDetails(conversation: value, entries: entries, deviceId: "device")
        #expect(details.reason == .missingResult)
        #expect(details.savedResults == 1 && details.unconfirmedResults == 1)
        #expect(details.completedPlanItems == 1 && details.totalPlanItems == 3)
        #expect(details.nextPlanStep == "Fix selectors")
    }

    @Test(arguments: ["timeout", "cancelled"])
    func `structured outcomes explain the interruption without claiming no effects`(status: String) {
        let value = AskRecoveryFixture.conversation()
        let receipt = AskToolResultRequest(
            runId: "run",
            deviceId: "device",
            toolCallId: "call",
            content: "private error",
            isError: true,
            harness: .init(version: 1, outcome: .init(status: status))
        )
        let entry = AskExecutionEntry(id: "run/call", audit: AskRecoveryFixture.audit(value), receipt: .tool(receipt))
        let details = AskRecoveryDetails(conversation: value, entries: [entry], deviceId: "device")
        #expect(details.reason == (status == "timeout" ? .timedOut : .interrupted))
        #expect(details.savedResults == 1 && details.unconfirmedResults == 1)
        #expect(!details.reasonKey.contains("private"))
    }

    @Test func `storage failure other device and unsynced results have different next steps`() {
        let value = AskRecoveryFixture.conversation()
        let entry = AskExecutionEntry(
            id: "run/call",
            audit: AskRecoveryFixture.audit(value),
            receipt: AskRecoveryFixture.receipt(value)
        )
        #expect(AskRecoveryDetails(conversation: value, entries: [entry], deviceId: "device").reason == .savedResults)
        #expect(AskRecoveryDetails(conversation: value, entries: [entry], deviceId: "other").reason == .otherDevice)
        #expect(AskRecoveryDetails(
            conversation: value,
            entries: [entry, .init(id: "unavailable", audit: nil, receipt: nil)],
            deviceId: "device"
        ).reason == .storage)
        #expect(AskRecoveryDetails(conversation: value, entries: [.init(id: "legacy", audit: nil)], deviceId: "device")
            .reason == .missingResult)
    }

    @Test func `known failure codes and explicit limits are distinguished from an unrecorded cause`() {
        var value = AskRecoveryFixture.conversation(model: true)
        value.run?.errorCode = "MODEL_TIMEOUT"
        #expect(AskRecoveryDetails(conversation: value, entries: [], deviceId: "device").reason == .timedOut)
        value.run?.errorCode = "MODEL_REQUEST_FAILED"
        #expect(AskRecoveryDetails(conversation: value, entries: [], deviceId: "device")
            .reason == .modelFailure("ask.failure.request"))
        value.run?.errorCode = "PROVIDER_SECRET"
        value.run?.error = "private provider response"
        #expect(AskRecoveryDetails(conversation: value, entries: [], deviceId: "device").reason == .unrecorded)
        value.run?.maxSteps = 10
        value.run?.steps = 10
        #expect(AskRecoveryDetails(conversation: value, entries: [], deviceId: "device").reason == .stepLimit)
        value.run?.executionMode = .continuous
        value.run?.status = "cancelled"
        #expect(AskRecoveryDetails(conversation: value, entries: [], deviceId: "device").reason == .stopped)
    }

    @Test func `blocked inspection quotes its own explanation and bounds long plan text`() {
        var value = AskRecoveryFixture.conversation()
        value.run?.internalRecovery = .init(phase: .blocked, handledCallIds: [], uncertainCallIds: ["call"],
                                            evidenceStart: 0, startedStep: 1,
                                            explanation: "The remote state cannot be read.")
        value.run?.plan = [.init(step: String(repeating: "x", count: 1000), status: "pending")]
        let details = AskRecoveryDetails(conversation: value, entries: [], deviceId: "device")
        #expect(details.reason == .inspectionBlocked)
        #expect(details.inspectionExplanation == "The remote state cannot be read.")
        #expect(details.nextPlanStep?.count == 400)
    }

    @Test func `detail copy is available in every language without execution internals`() throws {
        let suffixes = ["title", "step", "notStarted", "why", "progress", "next", "inspectionNote", "savedCount",
                        "noSaved", "unconfirmedCount", "planCount", "nextPlan", "nextStorage", "pending",
                        "reason.storage", "reason.device", "reason.timeout", "reason.interrupted", "reason.missing",
                        "reason.saved", "reason.blocked", "reason.limit", "reason.stopped", "reason.unrecorded"]
        let keys = suffixes.map { "ask.recovery.detail." + $0 } + AskRecoveryAction.allCases.map(\.detailKey)
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let text = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(!text.isEmpty && text != key)
                #expect(!text.contains("receipt") && !text.contains("operationId"))
            }
        }
    }
}
