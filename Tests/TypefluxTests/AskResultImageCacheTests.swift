import AppKit
import Testing
@testable import Typeflux

@Suite("Asynchronous launcher images", .serialized)
@MainActor
struct AskResultImageCacheTests {
    @Test func coalescesRequestsCachesAndInvalidatesByFileVersion() async throws {
        var calls = 0
        let expected = NSImage(size: .init(width: 28, height: 28))
        let cache = AskResultImageCache { _ in
            calls += 1
            try? await Task.sleep(for: .milliseconds(20))
            return expected
        }
        let key = AskResultImageCache.Key(url: URL(fileURLWithPath: "/synthetic.pdf"), thumbnail: true)
        #expect(cache.cached(key) == nil)
        let first = Task { await cache.image(key) }
        let second = Task { await cache.image(key) }
        #expect(await first.value === expected)
        #expect(await second.value === expected)
        #expect(calls == 1)
        #expect(cache.cached(key) === expected)
        #expect(await cache.image(key) === expected)
        var changed = key
        changed.modified = Date()
        #expect(await cache.image(changed) === expected)
        #expect(calls == 2)
    }

    @Test func cancellingOneConsumerKeepsTheOtherButCancellingAllStopsTheLoader() async throws {
        var calls = 0
        var cancelled = false
        let cache = AskResultImageCache { _ in
            calls += 1
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { cancelled = true; return nil }
            return NSImage(size: .init(width: 28, height: 28))
        }
        let key = AskResultImageCache.Key(url: URL(fileURLWithPath: "/synthetic.pdf"), thumbnail: false)
        let first = Task { await cache.image(key) }
        let second = Task { await cache.image(key) }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        #expect(await second.value != nil)
        #expect(await first.value == nil)
        #expect(!cancelled && calls == 1)
        let other = AskResultImageCache.Key(url: URL(fileURLWithPath: "/other.pdf"), thumbnail: false)
        let last = Task { await cache.image(other) }
        try await Task.sleep(for: .milliseconds(10))
        last.cancel()
        #expect(await last.value == nil)
        #expect(cancelled)
        #expect(cache.cached(other) == nil)
    }

    @Test func aCancelledRequestDoesNotStartLoading() async {
        var calls = 0
        let cache = AskResultImageCache { _ in calls += 1; return nil }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(.init(url: URL(fileURLWithPath: "/cancelled"), thumbnail: false))
        }
        #expect(await task.value == nil)
        #expect(calls == 0)
    }
}
