import AppKit
import Testing
@testable import Typeflux

@Suite("Asynchronous launcher images", .serialized, .exclusiveUIState)
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
        var firstImage: NSImage?
        var secondImage: NSImage?
        let first = Task { firstImage = await cache.image(key) }
        let second = Task { secondImage = await cache.image(key) }
        await first.value
        await second.value
        #expect(firstImage === expected)
        #expect(secondImage === expected)
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
        var firstImage: NSImage?
        var secondImage: NSImage?
        let first = Task { firstImage = await cache.image(key) }
        let second = Task { secondImage = await cache.image(key) }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        await second.value
        await first.value
        #expect(secondImage != nil)
        #expect(firstImage == nil)
        #expect(!cancelled && calls == 1)
        let other = AskResultImageCache.Key(url: URL(fileURLWithPath: "/other.pdf"), thumbnail: false)
        var lastImage: NSImage?
        let last = Task { lastImage = await cache.image(other) }
        try await Task.sleep(for: .milliseconds(10))
        last.cancel()
        await last.value
        #expect(lastImage == nil)
        #expect(cancelled)
        #expect(cache.cached(other) == nil)
    }

    @Test func aCancelledRequestDoesNotStartLoading() async {
        var calls = 0
        let cache = AskResultImageCache { _ in calls += 1; return nil }
        var image: NSImage?
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            image = await cache.image(.init(url: URL(fileURLWithPath: "/cancelled"), thumbnail: false))
        }
        await task.value
        #expect(image == nil)
        #expect(calls == 0)
    }

    @Test func aMissingImageIsNotCachedAndTheNextRequestCanRetry() async {
        var calls = 0
        let expected = NSImage(size: .init(width: 28, height: 28))
        let cache = AskResultImageCache { _ in
            calls += 1
            return calls == 1 ? nil : expected
        }
        let key = AskResultImageCache.Key(url: URL(fileURLWithPath: "/retry.pdf"), thumbnail: true)
        #expect(await cache.image(key) == nil)
        #expect(cache.cached(key) == nil)
        #expect(await cache.image(key) === expected)
        #expect(cache.cached(key) === expected)
        #expect(calls == 2)
    }
}
