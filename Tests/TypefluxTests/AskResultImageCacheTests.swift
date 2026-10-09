import AppKit
import Testing
@testable import Typeflux

@Suite("Asynchronous launcher images", .serialized, .exclusiveUIState)
@MainActor
struct AskResultImageCacheTests {
    @Test func prefetchSurvivesRowCancellationAndWarmsRecreatedRows() async throws {
        var calls = 0
        var finish: CheckedContinuation<NSImage?, Never>?
        let expected = NSImage(size: .init(width: 28, height: 28))
        let cache = AskResultImageCache { _ in
            calls += 1
            return await withCheckedContinuation { finish = $0 }
        }
        let key = AskResultImageCache.Key(url: URL(fileURLWithPath: "/prefetched.txt"), thumbnail: false)
        cache.prefetch([key, key])
        try await AskQuickSearchSessionTests.wait { finish != nil }
        let row = Task { await cache.image(key) }
        await Task.yield()
        row.cancel()
        finish?.resume(returning: expected)
        #expect(await row.value == nil)
        try await AskQuickSearchSessionTests.wait { cache.cached(key) != nil }
        #expect(cache.cached(key) === expected, "Replacing rows must not discard prefetched icons")
        cache.prefetch([key])
        #expect(await cache.image(key) === expected)
        #expect(calls == 1)
    }

    @Test(arguments: [CGFloat(1), 2])
    func finderIconsRasterizeOnlyTheDisplaySize(scale: CGFloat) async throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let image = try #require(await AskFinderIcon.image(for: url, scale: scale))
        #expect(image.size == NSSize(width: 28, height: 28))
        #expect(image.representations.count == 1)
        #expect(image.representations.first?.pixelsWide == Int(28 * scale))
        #expect(image.representations.first?.pixelsHigh == Int(28 * scale))
    }

    @Test func ordinaryFileIconsUseTheFinderImagePath() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("Launcher icon".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = AskResultImageCache()
        let image = try #require(await cache.image(.init(url: url, thumbnail: false, scale: 2)))
        #expect(image.representations.first?.pixelsWide == 56)
        #expect(image.size == NSSize(width: 28, height: 28))
    }

    @Test func hiddenRelativeApplicationLinksShareTheResolvedCacheAndPendingRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        let target = root.appendingPathComponent("System/Cryptexes/App/System/Applications/Safari.app",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = applications.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(atPath: link.path,
            withDestinationPath: "../System/Cryptexes/App/System/Applications/Safari.app")
        var hidden = URLResourceValues()
        hidden.isHidden = true
        var hiddenLink = link
        try hiddenLink.setResourceValues(hidden)
        let expected = NSImage(size: .init(width: 28, height: 28))
        let modified = Date(timeIntervalSinceReferenceDate: 100)
        var calls = 0
        let cache = AskResultImageCache { key in
            #expect(key.url == target)
            #expect(key.modified == modified && !key.thumbnail && key.scale == 1)
            calls += 1
            try? await Task.sleep(for: .milliseconds(20))
            return expected
        }
        let aliasKey = AskResultImageCache.Key(url: link, thumbnail: false, modified: modified, scale: 1)
        var targetKey = aliasKey
        targetKey.url = target
        let alias = Task { await cache.image(aliasKey) }
        let direct = Task { await cache.image(targetKey) }
        #expect(await alias.value === expected)
        #expect(await direct.value === expected)
        #expect(await cache.image(aliasKey) === expected)
        #expect(cache.cached(targetKey) === expected)
        #expect(cache.cached(aliasKey) === expected, "A recreated row must show the alias icon without a placeholder")
        #expect(calls == 1, "Aliases must coalesce and use the resolved path as the cache key")
    }

    @Test func retargetingAnApplicationLinkLoadsTheNewBundleInsteadOfTheOldCachedIcon() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.app", isDirectory: true)
        let second = root.appendingPathComponent("Second.app", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let firstIcon = NSImage(size: .init(width: 28, height: 28))
        let secondIcon = NSImage(size: .init(width: 32, height: 32))
        var loaded: [URL] = []
        let cache = AskResultImageCache { key in
            loaded.append(key.url)
            return key.url == first ? firstIcon : secondIcon
        }
        let key = AskResultImageCache.Key(url: link, thumbnail: false)
        #expect(await cache.image(key) === firstIcon)
        #expect(cache.cached(key) === firstIcon)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(await cache.image(key) === secondIcon)
        #expect(cache.cached(key) === secondIcon)
        #expect(loaded == [first, second])
    }

    @Test func nonApplicationLinksKeepTheirOriginalPreviewURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.pdf"), link = root.appendingPathComponent("Alias.pdf")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cache = AskResultImageCache { key in
            #expect(key.url == link && key.thumbnail)
            return NSImage(size: .init(width: 28, height: 28))
        }
        #expect(await cache.image(.init(url: link, thumbnail: true)) != nil)
    }

    @Test func aCancelledApplicationIconLoadDoesNotPublishAnImage() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await AskFinderIcon.image(for: URL(fileURLWithPath: "/missing.app"))
        }
        #expect(await task.value == nil)
    }

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
