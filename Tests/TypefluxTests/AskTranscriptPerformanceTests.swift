import AppKit
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Long transcript performance", .serialized, .exclusiveUIState)
@MainActor
struct AskTranscriptPerformanceTests {
    private final class RowDriver: ObservableObject {
        @Published var revision = 1
        @Published var noise = 0
        var builds = 0
    }
    private struct RowHost: View {
        @ObservedObject var driver: RowDriver
        var body: some View {
            VStack {
                Text("Noise \(driver.noise)")
                let revision = driver.revision
                let plainDriver = driver
                AskTranscriptRowBoundary(key: revision) {
                    let _ = { plainDriver.builds += 1 }()
                    Text("Revision \(revision)")
                }.equatable()
            }
        }
    }

    @Test func unchangedRowDoesNotRebuildItsContentHierarchy() async throws {
        let driver = RowDriver()
        let host = NSHostingView(rootView: RowHost(driver: driver))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        driver.noise = 1
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initial = driver.builds
        for index in 2...101 { driver.noise = index; host.layoutSubtreeIfNeeded() }
        #expect(driver.builds == initial)
        driver.revision = 2
        host.layoutSubtreeIfNeeded()
        #expect(driver.builds > initial)
    }

    @Test func revisionCacheSkipsHistoryTraversalAndInvalidatesEveryInput() {
        let cache = AskActivityOutputCache()
        let messages = Self.messages(turns: 100, steps: 50)
        var traversals = 0
        func visible() -> [AskMessage] { traversals += 1; return messages.filter { $0.role != "tool" } }
        func results() -> [AskMessage] { traversals += 1; return messages.filter { $0.role == "tool" } }
        let initial = cache.prepare(conversationID: "a", revision: 1, messages: visible(), results: results(), changes: [:])
        let start = ContinuousClock.now
        for _ in 0..<1000 {
            _ = cache.prepare(conversationID: "a", revision: 1, messages: visible(), results: results(), changes: [:])
        }
        print("TRANSCRIPT_CACHE 1000 hits, \(messages.count) messages: \(start.duration(to: .now))")
        #expect(traversals == 2)
        #expect(cache.preparationCount == 1)
        let changed = cache.prepare(conversationID: "a", revision: 2, messages: visible() + [
            .init(id: "new", role: "user", text: "New question", createdAt: .distantPast)
        ], results: results(), changes: [:])
        #expect(changed.count > initial.count)
        #expect(traversals == 4)
        _ = cache.prepare(conversationID: "b", revision: 2, messages: [], results: [], changes: [:])
        #expect(cache.resultsByID.isEmpty)
        #expect(cache.prepare(conversationID: "b", revision: 2, messages: [], results: [], changes: [:]).isEmpty)
    }

    @Test func streamingTailMatchesFullPreparationWithoutTraversingHistory() {
        let cache = AskActivityOutputCache()
        let all = Self.messages(turns: 20, steps: 50)
        let messages = Array(all.filter { $0.role != "tool" }.dropLast())
        let results = all.filter { $0.role == "tool" }
        let lastID = messages.last!.id
        let changes = [lastID: [AskWorkspaceFileChange(path: "site/index.html", kind: .added)]]
        _ = cache.prepare(conversationID: "chat", revision: 1, messages: messages, results: results, changes: changes)
        let decodes = cache.decodeCount, preparations = cache.preparationCount
        for index in 0..<30 {
            let call = AskToolCall(id: "live-tool", function: .init(name: "files", arguments: #"{"action":"read"}"#))
            let live = AskMessage(id: "live", role: "assistant", text: index % 3 == 0 ? "" : "Stream \(index)",
                toolCalls: index % 3 == 2 ? nil : [call], createdAt: .distantPast, reasoning: "Thinking", runId: "live-run")
            let actual = cache.appendingProgress(live)
            let expected = AskActivity.items(messages + [live], results: results, fileChanges: changes)
            #expect(actual == expected)
            #expect(cache.appendingProgress(live) == expected)
        }
        #expect(cache.decodeCount == decodes)
        #expect(cache.preparationCount == preparations)
        #expect(cache.appendingProgress(messages.last) == cache.appendingProgress(nil))
        // Out-of-order receipts and file changes must use the complete evidence path.
        let live = AskMessage(id: "live", role: "assistant", text: "", toolCalls: [
            .init(id: "live-tool", function: .init(name: "web_fetch", arguments: #"{"url":"https://example.com"}"#))
        ], createdAt: .distantPast, runId: "live-run")
        let receipts = results + [AskMessage(id: "receipt", role: "tool", text: "Fetched", toolCallId: "live-tool", createdAt: .distantPast)]
        _ = cache.prepare(conversationID: "chat", revision: 2, messages: messages, results: receipts, changes: changes)
        #expect(cache.appendingProgress(live) == AskActivity.items(messages + [live], results: receipts, fileChanges: changes))
        _ = cache.prepare(conversationID: "chat", revision: 3, messages: messages + [live], results: receipts, changes: changes)
        #expect(cache.appendingProgress(live) == cache.appendingProgress(nil))
    }

    @Test func recoveryPresentationIsConstantTimeBetweenJournalOrConversationUpdates() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let value = AskRecoveryFixture.conversation()
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        let entries = (0..<10000).map { AskExecutionEntry(id: "receipt-\($0)") }
        fixture.model.recoveryEntries[value.id] = entries
        let before = fixture.model.recoveryPresentationBuilds
        let reference = AskRecoveryPresentation(run: value.run, entries: entries, deviceId: "device", local: false)
        for _ in 0..<1000 { #expect(fixture.model.recoveryPresentation == reference) }
        #expect(fixture.model.recoveryPresentationBuilds == before + 1)
        fixture.model.recoveryEntries[value.id] = []
        #expect(fixture.model.recoveryPresentation == AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: false))
        #expect(fixture.model.recoveryPresentationBuilds == before + 2)
        let revision = fixture.model.transcriptRevision
        fixture.model.fileChanges["run"] = []
        #expect(fixture.model.transcriptRevision > revision)
        fixture.model.newConversation()
        #expect(fixture.model.recoveryPresentation == AskRecoveryPresentation(run: nil, entries: [], deviceId: "device", local: false))
    }

    @Test func durableMessageFactsSurviveStreamingAndRefreshWithSnapshots() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskConversation(id: "facts", title: "Facts", revision: 1, updatedAt: .distantPast,
                                    messages: Self.messages(turns: 100, steps: 20))
        value.run = .init(id: "facts-run", deviceId: "device", status: "running", steps: 1,
                          updatedAt: .distantPast, tools: [], pending: [], assistantId: "new-answer")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.externallyDrivenConversations.insert(value.id)
        for _ in 0..<100 {
            #expect(fixture.model.imageRecoveryTarget == nil)
            #expect(fixture.model.showsResponseWaiting)
        }
        #expect(fixture.model.cachedConversationImages == false)
        #expect(fixture.model.cachedRunHasResponseText == false)
        fixture.model.applyFeatureQuickProgress(.init(owner: fixture.model.owner, id: value.id, runID: "facts-run",
            complete: false, progress: .init(text: "An answer is arriving")))
        #expect(!fixture.model.showsResponseWaiting)
        #expect(fixture.model.cachedRunHasResponseText == false)
        value.revision += 1
        value.messages.append(.init(id: "new-answer", role: "assistant", text: "Saved answer", createdAt: .distantPast))
        value.messages[0].image = "data:image/jpeg;base64,YQ=="
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
        #expect(fixture.model.hasConversationImages)
        #expect(fixture.model.runHasResponseText)
        value.revision += 1
        value.run?.assistantId = "next-answer"
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
        #expect(!fixture.model.runHasResponseText)
        fixture.model.newConversation()
        #expect(!fixture.model.hasConversationImages)
        #expect(!fixture.model.runHasResponseText)
    }

    @Test func scrollAdjustmentsCoalesceAndCancelStaleConversation() async throws {
        let scheduler = AskTranscriptScrollScheduler()
        var values: [Int] = []
        for value in 0..<100 { scheduler.schedule { values.append(value) } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(values == [99])
        scheduler.schedule { values.append(-1) }
        scheduler.cancel()
        scheduler.schedule { values.append(100) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(values == [99, 100])
    }

    /// Exercises the production conversation view, its lazy rows and TextKit layout.
    /// No network or agent tools are invoked. The window is test-owned.
    @Test func longConversationWindowScrollStress() async throws {
        let suite = "scroll-stress-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        let count = Int(ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_TURNS"] ?? "100") ?? 100
        var messages = Self.messages(turns: count, steps: 20)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_RECORD"] {
            let record = try AskCoding.decoder().decode(AskLocalRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            messages = record.conversation.messages
        }
        let streaming = ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_IDLE"] != "1"
        let toolStreaming = ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_TOOLS"] == "1"
        let continuous = ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_CONTINUOUS"] == "1"
        var value = AskConversation(id: "scroll-stress", title: "Long conversation scroll stress", revision: 1,
                                    updatedAt: .distantPast, messages: messages)
        if streaming {
            value.run = .init(id: "stress-run", deviceId: "device", status: "running", steps: 2000,
                              updatedAt: .distantPast, tools: [], pending: [])
            value.run?.assistantId = "streaming-answer"
        }
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.externallyDrivenConversations.insert(value.id)
        let host = NSHostingView(rootView: AskConversationView(model: fixture.model).defaultAppStorage(defaults))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Typeflux Scroll Stress"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try #require(scrollViews(host).max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }))
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.bounds.height * 1.2)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        var costs: [Double] = []
        let builds = fixture.model.recoveryPresentationBuilds
        for index in 0..<180 {
            let start = ContinuousClock.now
            let limit = max(0, document.frame.height - scroll.contentSize.height)
            let fraction = CGFloat(index < 90 ? index : 179 - index) / 89
            // A fixed 48-point increment separates ordinary scrolling from whole-history jumps.
            let offset = continuous ? min(limit, CGFloat(index < 90 ? index : 179 - index) * 48) : limit * fraction
            scroll.contentView.scroll(to: .init(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            if streaming {
                let progress = toolStreaming
                    ? AskStreamProgress(toolCalls: [.init(id: "streaming-tool", function: .init(name: "files",
                        arguments: "{\"action\":\"write\",\"path\":\"site/app.js\",\"content\":\"" + String(repeating: "content ", count: index + 1)))])
                    : AskStreamProgress(text: "Live answer " + String(repeating: "word ", count: index + 1))
                fixture.model.applyFeatureQuickProgress(.init(owner: fixture.model.owner, id: value.id, runID: "stress-run",
                    complete: false, progress: progress))
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let duration = start.duration(to: .now).components
            costs.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            try await Task.sleep(for: .milliseconds(16))
        }
        if streaming {
            if toolStreaming { #expect(fixture.model.inferenceProgress[value.id]?.toolCalls.count == 1) }
            else { #expect(fixture.model.inferenceProgress[value.id]?.text.contains("Live answer") == true) }
        }
        costs.sort()
        let p95 = costs[Int(Double(costs.count - 1) * 0.95)]
        print("TRANSCRIPT_SCROLL continuous=\(continuous) streaming=\(streaming) tools=\(toolStreaming) messages=\(messages.count) samples=\(costs.count) p50_ms=\(costs[costs.count / 2]) p95_ms=\(p95) max_ms=\(costs.last!)")
        #expect(fixture.model.recoveryPresentationBuilds <= builds + 1)
        // Debug + coverage has substantial overhead. Actual app sampling complements this guard.
        #expect(p95 < 50, "Sustained main-thread work must not stall scrolling: \(p95) ms")
        #expect(costs.last! < 250, "No individual layout stall may exceed 250 ms")
        // Read older content while new text arrives: the view must not pull us to the end.
        scroll.contentView.scroll(to: .init(x: 0, y: 0))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        if streaming {
            fixture.model.applyFeatureQuickProgress(.init(owner: fixture.model.owner, id: value.id, runID: "stress-run",
                complete: false, progress: .init(text: "Still reading older messages")))
        }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY > 100)
        // Returning to the end resumes following, including delayed Markdown layout.
        // Lazy rows refine document height as they enter the viewport. Reach the actual
        // end before ending the gesture; a single jump can target an obsolete estimate.
        for _ in 0..<4 {
            scroll.contentView.scroll(to: .init(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY <= 13)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        if streaming {
            fixture.model.applyFeatureQuickProgress(.init(owner: fixture.model.owner, id: value.id, runID: "stress-run",
                complete: false, progress: .init(text: "**Latest streamed answer**\n\n" + String(repeating: "More verified content.\n\n", count: 20))))
        }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY <= 13)
        // Exercise production ScrollViewReader anchors for off-screen historical answers.
        // ForEach owns each message identity; redundant .id modifiers must not be needed.
        if ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_RECORD"] == nil {
            func editors(_ view: NSView) -> [AskTranscriptText.Editor] {
                (view as? AskTranscriptText.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
            }
            for target in [0, count / 2] {
                fixture.model.referenceLocation = "answer-\(target)"
                var found = false
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(50))
                    host.layoutSubtreeIfNeeded()
                    found = editors(host).contains { editor in
                        editor.string.hasPrefix("Website \(target) verified")
                            && editor.convert(editor.bounds, to: document).intersects(scroll.documentVisibleRect)
                    }
                    if found { break }
                }
                #expect(found, "Historical message anchor must remain visible: answer-\(target)")
            }
        }
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_STRESS_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }


    @Test func streamUpdatesDoNotInvalidateUnrelatedConversationViews() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.run?.inference = nil
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.externallyDrivenConversations.insert(value.id)
        var broad = 0, stream = 0, activity = 0
        let subscriptions = [fixture.model.objectWillChange.sink { broad += 1 },
            fixture.model.transcriptStream.objectWillChange.sink { stream += 1 },
            fixture.model.agentActivityChanges.sink { activity += 1 }]
        let revision = fixture.model.transcriptRevision
        fixture.model.applyFeatureQuickProgress(.init(owner: fixture.model.owner, id: value.id, runID: value.run!.id,
            complete: false, progress: .init(text: "Visible streamed answer")))
        #expect(broad == 0)
        #expect(stream == 1)
        #expect(activity == 1)
        #expect(fixture.model.liveProgress(fixture.model.selected!)?.text == "Visible streamed answer")
        #expect(fixture.model.transcriptRevision == revision)
        withExtendedLifetime(subscriptions) {}
    }

    private static func messages(turns: Int, steps: Int) -> [AskMessage] {
        var messages: [AskMessage] = []
        for turn in 0..<turns {
            let run = "run-\(turn)"
            messages.append(.init(id: "q-\(turn)", role: "user", text: "Build and verify the website \(turn)", createdAt: .distantPast, runId: run))
            for step in 0..<steps {
                let id = "\(turn)-\(step)"
                let call = AskToolCall(id: id, function: .init(name: "files", arguments: #"{"action":"read","path":"index.html"}"#))
                messages.append(.init(id: "call-" + id, role: "assistant", text: "", toolCalls: [call], createdAt: .distantPast, runId: run))
                messages.append(.init(id: "result-" + id, role: "tool", text: "File contents \(id) " + String(repeating: "verified content ", count: 30), toolCallId: id, createdAt: .distantPast, runId: run))
            }
            messages.append(.init(id: "answer-\(turn)", role: "assistant",
                text: "**Website \(turn) verified**\n\nThe responsive layout is ready.\n\n- Navigation works\n- Product filters work\n- Mobile layout verified\n\n```js\nconst ready = true;\n```",
                createdAt: .distantPast, runId: run))
        }
        return messages
    }
}
