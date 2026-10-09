import Foundation
import Testing
@testable import Typeflux

@Suite("Ask usage detail loading")
@MainActor
struct AskUsageDetailsTests {
    private func item(_ id: String) -> AskUsageInvocation {
        .init(id: id, runId: "run", modelRef: "cloud:default", purpose: "answer", createdAt: Date(),
              source: "provider", status: "confirmed", version: 1)
    }

    @Test func noRecordsIsAnEmptyStateWithoutARequest() async {
        let details = AskUsageDetails()
        var calls = 0
        await details.load(key: "new", hasRecords: false, reset: true) { _ in
            calls += 1
            throw AskLocalError.message("Must not request")
        }
        #expect(calls == 0 && details.items.isEmpty && !details.loading && !details.loadError)
        #expect(details.cursor == nil)
    }

    @Test func failureRetryAndPagingPreserveScopeAndDeduplicate() async {
        let details = AskUsageDetails()
        await details.load(key: "c/run/1", hasRecords: true, reset: true) { cursor in
            #expect(cursor == nil)
            throw AskLocalError.message("Offline")
        }
        #expect(details.loadError && !details.loading)
        await details.load(key: "c/run/1", hasRecords: true, reset: false) { cursor in
            #expect(cursor == nil)
            return AskUsagePage(items: [item("a"), item("a")], nextCursor: 42)
        }
        #expect(!details.loadError && details.items.map(\.id) == ["a"])
        await details.load(key: "c/run/1", hasRecords: true, reset: false) { cursor in
            #expect(cursor == 42)
            return AskUsagePage(items: [item("a"), item("b")], nextCursor: nil)
        }
        #expect(details.items.map(\.id) == ["a", "b"] && details.cursor == nil)
        await details.load(key: "other/all/1", hasRecords: true, reset: false) { cursor in
            #expect(cursor == nil)
            return AskUsagePage(items: [item("other")], nextCursor: nil)
        }
        #expect(details.items.map(\.id) == ["other"])
    }

    @Test(arguments: [false, true])
    func lateResponseOrErrorCannotRestoreTheDeletedConversation(fail: Bool) async {
        let details = AskUsageDetails()
        var continuation: CheckedContinuation<Void, Never>?
        let old = Task {
            await details.load(key: "old/run", hasRecords: true, reset: true) { _ in
                await withCheckedContinuation { continuation = $0 }
                if fail { throw AskLocalError.message("Late error") }
                return AskUsagePage(items: [item("old")], nextCursor: 42)
            }
        }
        while continuation == nil { await Task.yield() }
        var duplicateRequests = 0
        await details.load(key: "old/run", hasRecords: true, reset: false) { _ in
            duplicateRequests += 1
            return AskUsagePage(items: [], nextCursor: nil)
        }
        #expect(duplicateRequests == 0)
        await details.load(key: "new", hasRecords: false, reset: true) { _ in
            return AskUsagePage(items: [], nextCursor: nil)
        }
        continuation?.resume()
        await old.value
        #expect(details.items.isEmpty && details.cursor == nil && !details.loading && !details.loadError)
    }

    @Test(arguments: [false, true])
    func cancellationNeverBecomesALoadFailure(throwing: Bool) async {
        let details = AskUsageDetails()
        let task = Task {
            await details.load(key: "c", hasRecords: true, reset: true) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                if throwing { throw CancellationError() }
                return AskUsagePage(items: [item("ignored")], nextCursor: 42)
            }
        }
        await task.value
        #expect(details.items.isEmpty && !details.loading && !details.loadError)
    }

    @Test func recordDetectionDistinguishesDraftsFromRunsAndHistoricalUsage() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        #expect(!fixture.model.hasUsageRecords)
        var value = AskConversation(id: "c", title: "Empty", revision: 1, updatedAt: Date(), messages: [])
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(!fixture.model.hasUsageRecords)
        value.usage = .init(version: 1, since: Date(), historicalGap: false, total: .init(), runs: [:])
        value.revision += 1
        await fixture.api.seed(value)
        await fixture.model.select(value.id, reload: true)
        #expect(!fixture.model.hasUsageRecords)
        value.usage = .init(version: 1, since: Date(), historicalGap: false, total: .init(calls: 1), runs: [:])
        value.revision += 1
        await fixture.api.seed(value)
        await fixture.model.select(value.id, reload: true)
        #expect(fixture.model.hasUsageRecords)
        value.usage = nil
        var message = AskMessage(id: "answer", role: "assistant", text: "Answer", createdAt: Date())
        message.runId = "old-run"
        value.messages = [message]; value.revision += 1
        await fixture.api.seed(value)
        await fixture.model.select(value.id, reload: true)
        #expect(fixture.model.hasUsageRecords)
    }
}
