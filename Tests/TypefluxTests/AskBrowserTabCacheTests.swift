import AppKit
import Testing
@testable import Typeflux

private final class BrowserTabTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSinceReferenceDate: 100)
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }; return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; value += seconds
    }
}

private actor BrowserTabCacheRunner: ProcessCommandRunning {
    var calls = 0
    var suspended: CheckedContinuation<ProcessCommandResult, Never>?
    var pause = false
    static let original = #"{"tabs":[{"windowID":"1","tabID":"2","index":1,"title":"Original","url":"https://example.com"}]}"#
    static let updated = #"{"tabs":[{"windowID":"1","tabID":"3","index":2,"title":"Updated","url":"https://example.com/new"}]}"#

    func run(executablePath _: String, arguments: [String], environment _: [String: String]?,
             currentDirectoryURL _: URL?) async throws -> ProcessCommandResult {
        if arguments.last?.contains("app.activate()") == true {
            return .init(stdout: "focused", stderr: "", exitCode: 0)
        }
        calls += 1
        if pause {
            return await withCheckedContinuation { suspended = $0 }
        }
        return .init(stdout: Self.original, stderr: "", exitCode: 0)
    }

    func suspendNextRead() {
        pause = true
    }

    func finish() {
        pause = false
        suspended?.resume(returning: .init(stdout: Self.updated, stderr: "", exitCode: 0))
        suspended = nil
    }
}

@Suite(.exclusiveUIState)
@MainActor
struct AskBrowserTabCacheTests {
    private func waitForRead(_ runner: BrowserTabCacheRunner) async throws {
        for _ in 0 ..< 1000 {
            if await runner.suspended != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The tab refresh did not start")
    }

    @Test func `recent tabs return before refresh and forced refresh coalesces`() async throws {
        let clock = BrowserTabTestClock(), runner = BrowserTabCacheRunner()
        let service = AskBrowserSearchService(runner: runner, running: { _ in true }, clock: { clock.now() })
        let original = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        clock.advance(10)
        #expect(await service.cachedSnapshot(kind: .tab, browsers: [.chrome], interactive: true) == nil)
        await runner.suspendNextRead()
        let start = ContinuousClock.now
        let cached = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        #expect(start.duration(to: .now) < .milliseconds(100))
        #expect(cached.entries == original.entries)
        try await waitForRead(runner)
        let repeated = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        #expect(repeated.entries == original.entries)
        let forced = Task { await service.refreshSnapshot(kind: .tab, browsers: [.chrome], interactive: true) }
        await Task.yield()
        await runner.finish()
        let updated = await forced.value
        #expect(updated.entries.first?.title == "Updated")
        #expect(await service.cachedSnapshot(kind: .tab, browsers: [.chrome], interactive: true)?.entries == updated
            .entries)
        #expect(await runner.calls == 2)
    }

    @Test func `expired tabs await fresh read and do not cross browser or permission scopes`() async throws {
        let clock = BrowserTabTestClock(), runner = BrowserTabCacheRunner()
        let service = AskBrowserSearchService(runner: runner, running: { _ in true }, authorized: { _ in false },
                                              clock: { clock.now() })
        _ = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        clock.advance(60)
        await runner.suspendNextRead()
        var published = false
        let refresh = Task {
            let result = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
            published = true
            return result
        }
        try await waitForRead(runner)
        #expect(!published)
        #expect(await service.snapshot(kind: .tab, browsers: [.chrome], interactive: false).entries.isEmpty)
        #expect(await service.snapshot(kind: .tab, browsers: [], interactive: true).entries.isEmpty)
        await runner.finish()
        #expect(await refresh.value.entries.first?.title == "Updated")
        #expect(await runner.calls == 2)
    }

    @Test func `focusing invalidates an in flight read without restoring stale tabs`() async throws {
        let clock = BrowserTabTestClock(), runner = BrowserTabCacheRunner()
        let service = AskBrowserSearchService(runner: runner, running: { _ in true }, clock: { clock.now() })
        let initial = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        let target = try #require(initial.entries.first?.target)
        clock.advance(10)
        await runner.suspendNextRead()
        _ = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        try await waitForRead(runner)
        let pending = Task { await service.refreshSnapshot(kind: .tab, browsers: [.chrome], interactive: true) }
        // Let the explicit refresh attach to the same task before focus invalidates it.
        try await Task.sleep(for: .milliseconds(10))
        try await service.focus(target)
        await runner.finish()
        _ = await pending.value
        #expect(await service.cachedSnapshot(kind: .tab, browsers: [.chrome], interactive: true) == nil)
        #expect(await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true).entries.first?
            .title == "Original")
        #expect(await runner.calls == 3)
    }

    @Test func `explicit plugin refresh waits for latest and resets its option`() async throws {
        let clock = BrowserTabTestClock(), runner = BrowserTabCacheRunner()
        let service = AskBrowserSearchService(runner: runner, running: { _ in true }, clock: { clock.now() })
        let plugin = AskBrowserSearchPlugin(kind: .tab, service: service, settings: {
            var settings = AskBrowserSearchSettings(); settings.tabBrowsers = [.chrome]; return settings
        })
        var request = AskPluginRequest(text: "", origin: .argument, keyword: plugin.defaultKeywords[0], options: [:],
                                       interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        #expect(plan.debounce == .milliseconds(16))
        let initial = try await plugin.run(request, plan: plan)
        #expect(initial.actions.first?.kind == .rerun([AskBrowserSearchPlugin.refreshOption: "true"]))
        clock.advance(10)
        await runner.suspendNextRead()
        let cached = try await plugin.run(request, plan: plan)
        #expect(cached.items.first?.title == "Original" && cached.items.first?.valid == true)
        #expect(cached.rerunAfter == 3)
        try await waitForRead(runner)
        request.options[AskBrowserSearchPlugin.refreshOption] = "true"
        let forcedRequest = request
        let forced = Task { try await plugin.run(forcedRequest, plan: plan) }
        await Task.yield()
        await runner.finish()
        let output = try await forced.value
        #expect(output.items.first?.title == "Updated")
        #expect(output.variables[AskBrowserSearchPlugin.refreshOption] == "")
        #expect(await runner.calls == 2)
    }
}
