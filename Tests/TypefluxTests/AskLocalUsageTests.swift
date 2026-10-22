import Foundation
import Testing
@testable import Typeflux

@Suite("Local Ask usage", .exclusiveUIState)
@MainActor
struct AskLocalUsageTests {
    private let tokens = AskTokenUsage(promptTokens: 100, completionTokens: 20, totalTokens: 120, cachedTokens: 40)

    private func makeEngine(directory: URL, budgetEnabled: Bool = false) -> AskLocalEngine {
        // JSON storage uses whole-second ISO dates, so compare deterministic snapshots.
        AskLocalEngine(directory: directory, now: { Date(timeIntervalSince1970: 1_790_870_400) },
                       budgetEnabled: budgetEnabled)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ask-local-usage-" + UUID().uuidString)
    }

    private func send(_ engine: AskLocalEngine, id: String = "conversation") async throws -> AskConversation {
        try await engine.send(conversationId: id, request: .init(
            id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:test"
        ), token: "")
    }

    private func receipt(_ value: AskConversation, usage: AskTokenUsage? = nil,
                         failed: Bool = false) throws -> AskInferenceResult {
        let run = try #require(value.run)
        return try .init(runId: run.id, deviceId: run.deviceId, inferenceId: #require(run.inference?.id),
                         content: "Answer", usage: usage, failed: failed)
    }

    private func expectSameConversation(_ actual: AskConversation, _ expected: AskConversation) throws {
        // Tool schema JSON may reorder its raw bytes when decoded from disk.
        let encoder = AskCoding.encoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(expected))
    }

    @Test(arguments: [false, true])
    func `tokens persist and duplicate receipts count once`(budget: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root, budgetEnabled: budget)
        let queued = try await send(engine)
        #expect(queued.usage?.total.calls == 1)
        #expect(queued.usage?.total.pending == 1)
        #expect(queued.usage?.total.tokenText(0) == "—")
        #expect(queued.usage?.historicalGap == false)
        let request = try receipt(queued, usage: tokens)
        let done = try await engine.inferenceResult(conversationId: queued.id, request: request, token: "")
        #expect(done.run?.status == "completed")
        #expect(done.usage?.total == .init(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20,
                                           totalTokens: 120, calls: 1, external: 1))
        #expect(done.usage?.runs[request.runId] == done.usage?.total)
        let page = try await engine.usage(id: done.id, runId: request.runId, cursor: nil, token: "")
        let item = try #require(page.items.first)
        #expect(item.tokens == tokens && item.modelRef == "custom:test")
        #expect(item.source == "client" && item.status == "external" && item.microcredits == nil)
        #expect(item.messageId == done.messages.last?.id)
        #expect(page.nextCursor == nil)
        let duplicate = try await engine.inferenceResult(conversationId: queued.id, request: request, token: "")
        #expect(duplicate == done)
        let restored = makeEngine(directory: root, budgetEnabled: budget)
        try await expectSameConversation(restored.conversation(id: done.id, token: ""), done)
        #expect(try await restored.usage(id: done.id, runId: nil, cursor: nil, token: "").items == page.items)
        try await expectSameConversation(
            restored.inferenceResult(conversationId: done.id, request: request, token: ""),
            done
        )
    }

    @Test(arguments: [false, true])
    func `late usage after cancel and retry preserves content`(budget: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root, budgetEnabled: budget)
        let queued = try await send(engine)
        let old = try receipt(queued, usage: tokens)
        let cancelled = try await engine.cancel(conversationId: queued.id, runId: old.runId, token: "")
        #expect(cancelled.usage?.total.pending == 0 && cancelled.usage?.total.missing == 1)
        let retry = try await engine.retry(
            conversationId: queued.id,
            runId: old.runId,
            deviceId: "device",
            modelRef: nil,
            token: ""
        )
        let newer = try receipt(retry, usage: tokens)
        let done = try await engine.inferenceResult(conversationId: queued.id, request: newer, token: "")
        let restarted = makeEngine(directory: root, budgetEnabled: budget)
        let late = try await restarted.inferenceResult(conversationId: queued.id, request: old, token: "")
        #expect(late.revision == done.revision && late.updatedAt == done.updatedAt)
        #expect(late.messages == done.messages && late.run?.id == done.run?.id && late.run?.status == "completed")
        #expect(late.usage?.total.totalTokens == 240 && late.usage?.total.calls == 2)
        #expect(late.usage?.total.missing == 0)
        #expect(late.usage?.runs[old.runId]?.totalTokens == 120)
        #expect(late.usage?.runs[newer.runId]?.totalTokens == 120)
        let persisted = try await makeEngine(directory: root).conversation(id: queued.id, token: "")
        #expect(persisted.usage == late.usage)
        #expect(try await restarted.inferenceResult(conversationId: queued.id, request: old, token: "") == late)
    }

    @Test func `late usage from an earlier question never settles the new budget`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root, budgetEnabled: true)
        let queued = try await send(engine)
        let old = try receipt(queued, usage: tokens)
        _ = try await engine.cancel(conversationId: queued.id, runId: old.runId, token: "")
        let next = try await send(engine)
        #expect(next.run?.budgetRootId != queued.run?.budgetRootId)
        let late = try await engine.inferenceResult(conversationId: queued.id, request: old, token: "")
        #expect(late.run == next.run && late.messages == next.messages && late.revision == next.revision)
        #expect(late.usage?.runs[old.runId]?.totalTokens == 120)
        #expect(late.usage?.runs[next.run?.id ?? ""]?.totalTokens == 0)
        #expect(late.usage?.total.calls == 2)
    }

    @Test func `late usage from an unbudgeted run survives enabling budgets`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        let queued = try await send(engine)
        let old = try receipt(queued, usage: tokens)
        _ = try await engine.cancel(conversationId: queued.id, runId: old.runId, token: "")
        let enabled = makeEngine(directory: root, budgetEnabled: true)
        let next = try await send(enabled)
        #expect(queued.run?.budgetRootId == nil && next.run?.budgetRootId != nil)
        let late = try await enabled.inferenceResult(conversationId: queued.id, request: old, token: "")
        #expect(late.run == next.run && late.messages == next.messages && late.revision == next.revision)
        #expect(late.usage?.runs[old.runId]?.totalTokens == 120 && late.usage?.total.calls == 2)
    }

    @Test func `failures missing and invalid reports stay unknown`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        let reports: [AskTokenUsage?] = [nil, .init(promptTokens: -1, completionTokens: 1, totalTokens: 1), tokens]
        for (index, report) in reports.enumerated() {
            let queued = try await send(engine, id: "failure-\(index)")
            let request = try receipt(queued, usage: report, failed: true)
            let failed = try await engine.inferenceResult(conversationId: queued.id, request: request, token: "")
            #expect(failed.run?.status == "failed" && failed.usage?.total.calls == 1)
            #expect(failed.usage?.total.pending == 0)
            #expect(failed.usage?.total.missing == (index < 2 ? 1 : 0))
            #expect(failed.usage?.total.tokenText(failed.usage?.total.totalTokens ?? 0) == (index < 2 ? "—" : "120"))
        }
    }

    @Test func `partial cancellation can receive final usage without regressing`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        let queued = try await send(engine)
        var partial = try receipt(
            queued,
            usage: .init(promptTokens: 100, completionTokens: 5, totalTokens: 105, incomplete: true)
        )
        let cancelled = try await engine.cancel(
            conversationId: queued.id,
            runId: partial.runId,
            partial: partial,
            token: ""
        )
        #expect(cancelled.usage?.total.tokenText(105) == "≥105")
        let originalPartial = partial
        partial.usage = .init(promptTokens: 1, completionTokens: 1, totalTokens: 2, incomplete: true)
        #expect(try await engine.inferenceResult(conversationId: queued.id, request: partial, token: "") == cancelled)
        partial.usage = tokens
        let final = try await engine.inferenceResult(conversationId: queued.id, request: partial, token: "")
        #expect(final.run?.status == "cancelled" && final.messages == cancelled.messages)
        #expect(final.usage?.total.missing == 0 && final.usage?.total.totalTokens == 120)
        #expect(try await engine
            .inferenceResult(conversationId: queued.id, request: originalPartial, token: "") == final)
        partial.usage = nil
        #expect(try await engine.inferenceResult(conversationId: queued.id, request: partial, token: "") == final)
    }

    @Test func `unbound receipts cannot change local usage`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        let queued = try await send(engine)
        let valid = try receipt(queued, usage: tokens)
        _ = try await engine.cancel(conversationId: queued.id, runId: valid.runId, token: "")
        let before = try await engine.conversation(id: queued.id, token: "")
        for component in 0 ... 3 {
            var wrong = valid
            if component == 0 {
                wrong.deviceId = "other"
            }
            if component == 1 {
                wrong.runId = "other"
            }
            if component == 2 {
                wrong.inferenceId = "other"
            }
            await #expect(throws: AskLocalError.self) {
                _ = try await engine.inferenceResult(
                    conversationId: queued.id,
                    request: wrong,
                    token: component == 3 ? "cloud" : ""
                )
            }
            #expect(try await engine.conversation(id: queued.id, token: "") == before)
        }
    }

    @Test func `summaries and tool decisions are included in run totals`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        var value = try await send(engine)
        // Seed legacy history long enough to require a summary on the next turn.
        let run = try #require(value.run)
        value.run?.status = "completed"
        value.run?.inference = nil
        value.messages = (0 ..< 30).map { .init(
            id: "old-\($0)",
            role: $0.isMultiple(of: 2) ? "user" : "assistant",
            text: "History",
            createdAt: Date()
        ) }
        let legacy = AskLocalRecord(conversation: value)
        try AskCoding.encoder().encode(legacy).write(to: root.appendingPathComponent(value.id + ".json"))
        let restarted = makeEngine(directory: root)
        value = try await send(restarted)
        #expect(value.run?.id != run.id && value.run?.inference?.summaryThrough != nil)
        value = try await restarted.inferenceResult(
            conversationId: value.id,
            request: receipt(value, usage: tokens),
            token: ""
        )
        var decision = try receipt(value, usage: tokens)
        decision.toolCalls = [.init(
            id: "plan",
            type: "function",
            function: .init(name: "update_plan", arguments: #"{"items":[{"step":"Done","status":"completed"}]}"#)
        )]
        value = try await restarted.inferenceResult(conversationId: value.id, request: decision, token: "")
        value = try await restarted.inferenceResult(
            conversationId: value.id,
            request: receipt(value, usage: tokens),
            token: ""
        )
        #expect(value.run?.status == "completed")
        #expect(value.usage?.historicalGap == true)
        #expect(value.usage?.total.calls == 3 && value.usage?.total.totalTokens == 360)
        let page = try await restarted.usage(id: value.id, runId: value.run?.id, cursor: nil, token: "")
        #expect(page.items.map(\.purpose) == ["answer", "answer", "summary"])
        #expect(page.items.last?.messageId == nil)
    }

    @Test func `legacy files load and current inference starts metering`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        let queued = try await send(engine)
        let path = root.appendingPathComponent(queued.id + ".json")
        var legacy = try AskCoding.decoder().decode(AskLocalRecord.self, from: Data(contentsOf: path))
        legacy.localUsage = nil
        legacy.conversation.usage = nil
        try AskCoding.encoder().encode(legacy).write(to: path)
        let restarted = makeEngine(directory: root)
        #expect(try await restarted.usage(id: queued.id, runId: nil, cursor: nil, token: "").items.isEmpty)
        let done = try await restarted.inferenceResult(
            conversationId: queued.id,
            request: receipt(queued, usage: tokens),
            token: ""
        )
        #expect(done.usage?.total.totalTokens == 120 && done.usage?.historicalGap == false)
        try await restarted.delete(conversationId: done.id, token: "")
        await #expect(throws: AskLocalError.self) {
            _ = try await restarted.usage(id: done.id, runId: nil, cursor: nil, token: "")
        }
    }

    @Test func `regeneration keeps previously consumed tokens`() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(directory: root)
        let queued = try await send(engine)
        let done = try await engine.inferenceResult(
            conversationId: queued.id,
            request: receipt(queued, usage: tokens),
            token: ""
        )
        let regenerated = try await engine.regenerate(conversationId: done.id, request: .init(
            messageId: #require(done.messages.last?.id), deviceId: "device", modelRef: "custom:other"
        ), token: "")
        let final = try await engine.inferenceResult(
            conversationId: done.id,
            request: receipt(regenerated, usage: tokens),
            token: ""
        )
        #expect(final.messages.filter { $0.role == "assistant" }.count == 1)
        #expect(final.usage?.total.calls == 2 && final.usage?.total.totalTokens == 240)
        #expect(final.usage?.runs.count == 2)
        let page = try await engine.usage(id: done.id, runId: nil, cursor: nil, token: "")
        #expect(page.items.map(\.modelRef) == ["custom:other", "custom:test"])
    }

    @Test func `record helpers handle missing runs and monotonic partial reports`() {
        var record = AskLocalRecord(conversation: .init(
            id: "c",
            title: "Test",
            revision: 0,
            updatedAt: Date(),
            messages: []
        ))
        let inference = AskInference(id: "inference", payload: "{}")
        var report = AskInferenceResult(runId: "run", deviceId: "device", inferenceId: inference.id, content: "",
                                        usage: .init(
                                            promptTokens: 10,
                                            completionTokens: 0,
                                            totalTokens: 10,
                                            incomplete: true
                                        ))
        record.startUsage(inference, at: Date())
        record.closeUsage()
        let withoutRun = record.settleUsage(report)
        #expect(record.localUsage == nil && !withoutRun)
        record.conversation.run = .init(id: "run", deviceId: "device", status: "waiting_inference", steps: 0,
                                        updatedAt: Date(), tools: [], pending: [])
        record.startUsage(inference, at: Date())
        let queued = record.localUsage
        record.startUsage(inference, at: Date())
        #expect(record.localUsage == queued)
        let firstPartial = record.settleUsage(report)
        #expect(firstPartial)
        report.usage = .init(promptTokens: 10, completionTokens: 5, totalTokens: 15, incomplete: true)
        let newerPartial = record.settleUsage(report)
        #expect(newerPartial)
        #expect(record.conversation.usage?.total.totalTokens == 15)
        #expect(record.conversation.usage?.total.cachedInputTokens == nil)
        report.inferenceId = "other"
        let unknown = record.settleUsage(report)
        #expect(!unknown)
    }

    @Test func `paging has stable cursors and run filters`() {
        var ledger = AskLocalUsage(since: Date(), historicalGap: false)
        for index in 1 ... 105 {
            ledger.invocations.append(.init(deviceId: "device", usage: .init(
                id: "call-\(index)", runId: index.isMultiple(of: 2) ? "even" : "odd", modelRef: "custom:test",
                purpose: "answer", createdAt: Date(), tokens: tokens, source: "client", status: "external",
                version: Int64(index)
            )))
        }
        let first = ledger.page(runId: nil, cursor: nil)
        #expect(first.items.count == 50 && first.items.first?.id == "call-105" && first.nextCursor == 56)
        let second = ledger.page(runId: nil, cursor: first.nextCursor)
        #expect(second.items.count == 50 && second.items.first?.id == "call-55" && second.nextCursor == 6)
        let last = ledger.page(runId: nil, cursor: second.nextCursor)
        #expect(last.items.count == 5 && last.nextCursor == nil)
        #expect(Set((first.items + second.items + last.items).map(\.id)).count == 105)
        let odd = ledger.page(runId: "odd", cursor: nil)
        #expect(odd.items.count == 50 && odd.items.allSatisfy { $0.runId == "odd" })
        #expect(ledger.page(runId: "odd", cursor: odd.nextCursor).items.count == 3)
        #expect(ledger.page(runId: "missing", cursor: nil).items.isEmpty)
        #expect(ledger.page(runId: nil, cursor: 0).items.isEmpty)
        #expect(ledger.page(runId: nil, cursor: -1).items.isEmpty)
        #expect(ledger.summary.total.totalTokens == 12600 && ledger.summary.total.microcredits == 0)
    }

    @Test(arguments: [false, true])
    func `usage panel model reads local data without cloud requests`(signedIn: Bool) async throws {
        let root = directory()
        let suite = "ask-local-usage-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let engine = makeEngine(directory: root.appendingPathComponent("local"))
        let cloud = AskTestAPI()
        await cloud.setFailUsage(true)
        let queued = try await send(engine)
        let done = try await engine.inferenceResult(
            conversationId: queued.id,
            request: receipt(queued, usage: tokens),
            token: ""
        )
        let model = try AskConversationModel(api: AskRoutedAPI(cloud: cloud, local: engine),
                                             cache: AskConversationCache(
                                                 url: root.appendingPathComponent("cache.sqlite")
                                             ),
                                             tools: AskTestTools(),
                                             capture: AskTestCapture(), deviceId: "device",
                                             modelLibrary: AskModelLibrary(
                                                 defaults: defaults,
                                                 automaticallyLoadsCatalog: false
                                             ),
                                             defaults: defaults, session: { signedIn ? ("account", "token") : (
                                                 AskRoutedAPI.localOwner,
                                                 ""
                                             ) })
        model.lastConversationKind = .work // Predates conversation kinds: keep tool flows.
        defer { model.resetSession() }
        model.registerLocalHistory([.init(id: done.id, title: done.title, updatedAt: done.updatedAt)])
        await model.select(done.id)
        #expect(model.isSignedIn == signedIn && model.hasUsageRecords)
        #expect(model.selected?.usage == done.usage)
        let details = AskUsageDetails()
        await details.load(key: "local", hasRecords: model.hasUsageRecords, reset: true) { cursor in
            try await model.usagePage(id: done.id, runId: done.run?.id, cursor: cursor)
        }
        #expect(!details.loadError && details.items.first?.tokens == tokens)
        #expect(await cloud.usageRequests == 0)
    }
}
