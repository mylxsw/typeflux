import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Typeflux

@Suite("Ask usage detail loading", .exclusiveUIState)
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
    @Test func contextCardRendersNormalNearFullAndUnknownCapacity() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let reference = fixture.model.modelReference(launcher: false)
        for (index, values) in [(23_700, Optional(204_800)), (204_544, Optional(204_800)), (23_700, nil), (23_700, Optional(0))].enumerated() {
            let (input, capacity) = values
            var value = AskConversation(id: "context-card-\(index)", title: "Synthetic", revision: 1,
                                        updatedAt: Date(), messages: [])
            value.contextUsage = .init(modelRef: reference, inputTokens: input, outputReserve: 180_844,
                                       capacity: capacity, summarized: false)
            await fixture.api.seed(value)
            await fixture.model.select(value.id, reload: true)
            let context = try #require(fixture.model.usageContext)
            #expect(context.remaining == capacity.flatMap { $0 > 0 ? $0 - input : nil })
            let host = NSHostingView(rootView: AskUsagePanel(model: fixture.model, runId: .constant(nil), close: {})
                .frame(width: 420, height: 600))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            #expect(hasAccessibilityID("ask.usage.contextCard", in: window) == (context.remaining != nil))
            let composer = NSHostingView(rootView: AskComposer(model: fixture.model, availableWidth: 800,
                launcher: false, onToggleUsage: {}).frame(width: 800))
            let composerWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false)
            composerWindow.isReleasedWhenClosed = false
            composerWindow.contentView = composer
            defer { composerWindow.close() }
            composerWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            composer.layoutSubtreeIfNeeded()
            #expect(hasAccessibilityID("ask.usage.contextButton", in: composerWindow) == (context.remaining != nil))
        }
    }

    @Test func savedUnknownContextResolvesFromCatalogAndModelSwitchClearsStaleCapacity() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let known = RegisteredModel(id: "gpt-4o", name: "Known", reference: "custom:known")
        let unknown = RegisteredModel(id: "coding/auto", name: "Auto", reference: "custom:auto")
        try fixture.model.modelLibrary.addModels([known, unknown], providerID: "custom")
        #expect(AskModelChoices.caption(known) != nil)
        #expect(AskModelChoices.caption(unknown) == nil)
        var value = AskConversation(id: "context-fallback", title: "Saved", revision: 1, updatedAt: Date(), messages: [])
        value.modelRef = known.reference
        value.contextUsage = .init(modelRef: known.reference, inputTokens: 14_000, outputReserve: 4096,
            capacity: nil, summarized: false)
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(fixture.model.usageContext?.capacity == 128_000)
        #expect(fixture.model.usageContext?.remaining == 114_000)
        fixture.model.draft.modelRef = unknown.reference
        #expect(fixture.model.usageContext?.modelRef == unknown.reference)
        #expect(fixture.model.usageContext?.capacity == nil)
        fixture.model.draft.modelRef = known.reference
        value.contextUsage?.capacity = 32_000
        value.revision += 1
        await fixture.api.seed(value)
        await fixture.model.select(value.id, reload: true)
        #expect(fixture.model.usageContext?.capacity == 32_000)
        fixture.model.draft.modelRef = "custom:removed"
        #expect(fixture.model.usageContext?.capacity == nil)
    }

    private func hasAccessibilityID(_ identifier: String, in window: NSWindow) -> Bool {
        var seen = Set<ObjectIdentifier>()
        func find(_ value: Any) -> Bool {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return false }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier { return true }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return false }
            return (object.value(forKey: "accessibilityChildren") as? [Any] ?? []).contains(where: find)
        }
        return find(window)
    }
}
