import AppKit
import ImageIO
import SwiftUI
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private actor BrowserFaviconTestLoader {
    var calls = 0
    var canceled = false
    var data: Data?
    var delay: Duration
    init(data: Data?, delay: Duration = .milliseconds(20)) {
        self.data = data; self.delay = delay
    }

    func load(_: URL) async -> Data? {
        calls += 1
        do { try await Task.sleep(for: delay) }
        catch { canceled = true; return nil }
        return data
    }
}

private actor BrowserFaviconTestTransport: AskImageTransport {
    var request: URLRequest?
    var limit = 0
    var fails: Bool
    init(fails: Bool = false) {
        self.fails = fails
    }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        self.request = request; self.limit = limit
        if fails {
            throw URLError(.notConnectedToInternet)
        }
        return Data("icon".utf8)
    }
}

@Suite(.exclusiveUIState)
@MainActor
struct AskBrowserFaviconTests {
    private static let decodeImage: AskBrowserFaviconCache.Decoder = { data in
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 56
              ] as CFDictionary) else { throw MediaFailure.unreadable }
        return image
    }

    private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                   bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func `origins exclude paths queries credentials and non web tabs`() throws {
        let expected = URL(string: "https://example.com:8443/favicon.ico")
        #expect(AskBrowserFaviconCache
            .faviconURL(for: "https://user:secret@example.com:8443/private?q=token#fragment") == expected)
        #expect(AskBrowserFaviconCache.faviconURL(for: "http://localhost:8080/tab")?
            .absoluteString == "http://localhost:8080/favicon.ico")
        for text in [
            "file:///private/site.html",
            "chrome://settings",
            "about:blank",
            "javascript:alert(1)",
            "invalid",
            "https:///",
            ""
        ] {
            #expect(AskBrowserFaviconCache.faviconURL(for: text) == nil)
        }
        #expect(AskBrowserFaviconCache.faviconURL(for: "https://example.test/" + String(repeating: "x", count: 16 * 1024)) == nil)
        let fallback = URL(fileURLWithPath: "/Browser.app")
        var entry = AskBrowserSearchEntry(id: "tab", kind: .tab, browser: .chrome, title: "Site",
                                          url: "https://example.com/page", target: .init(browser: .chrome,
                                                                                         windowID: "1", tabID: "2",
                                                                                         index: 1,
                                                                                         url: "https://example.com/page"))
        #expect(try entry.item(settings: .init(), icon: .fileIcon(fallback)).icon == .websiteIcon(
            #require(URL(string: "https://example.com/favicon.ico")), fallback: fallback
        ))
        #expect(try entry.item(settings: .init()).icon == .websiteIcon(
            #require(URL(string: "https://example.com/favicon.ico")),
            fallback: nil, application: entry.browser.bundleID
        ))
        entry.kind = .bookmark; entry.target = nil
        #expect(entry.item(settings: .init(), icon: .fileIcon(fallback)).icon == .fileIcon(fallback))
        entry.kind = .tab; entry.url = "file:///tmp/site.html"
        #expect(entry.item(settings: .init(), icon: .fileIcon(fallback)).icon == .fileIcon(fallback))
        #expect(try AskPluginItemIcon.image(.websiteIcon(#require(expected), fallback: fallback)) == nil)
    }

    @Test func `concurrent rows share one downsampled image and recreated rows use cache`() async throws {
        let loader = try BrowserFaviconTestLoader(data: png())
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, decode: Self.decodeImage)
        let url = try #require(URL(string: "https://example.com/favicon.ico"))
        let first = Task { await cache.image(url) }, second = Task { await cache.image(url) }
        let image = try #require(await first.value)
        #expect(await second.value === image)
        #expect(await cache.image(url) === image)
        #expect(cache.cached(url) === image)
        let pixels = image.width
        #expect((26 ... 56).contains(pixels))
        #expect(image.height <= 56)
        #expect(await loader.calls == 1)
    }

    @Test func `failures use bounded negative cache and retry after expiry`() async throws {
        let url = try #require(URL(string: "https://example.com/favicon.ico"))
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let loader = BrowserFaviconTestLoader(data: nil, delay: .zero)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, clock: { now },
                                           decode: Self.decodeImage)
        #expect(await cache.image(url) == nil)
        #expect(await cache.image(url) == nil)
        #expect(await loader.calls == 1)
        now += 60
        #expect(await cache.image(url) == nil)
        #expect(await loader.calls == 2)
        for index in 0 ..< 257 {
            #expect(try await cache.image(#require(URL(string: "https://missing-\(index).test/favicon.ico"))) == nil)
        }
        for data in [Data("bad".utf8), Data(repeating: 1, count: 262_145)] {
            let invalid = AskBrowserFaviconCache(loader: { _ in data }, decode: Self.decodeImage)
            #expect(await invalid.image(url) == nil)
            #expect(invalid.cached(url) == nil)
        }
    }

    @Test func `canceling one row preserves others and canceling last stops download`() async throws {
        let loader = try BrowserFaviconTestLoader(data: png(), delay: .milliseconds(80))
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, decode: Self.decodeImage)
        let url = try #require(URL(string: "https://example.com/favicon.ico"))
        let first = Task { await cache.image(url) }, second = Task { await cache.image(url) }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        #expect(await first.value == nil)
        #expect(await second.value != nil)
        #expect(await loader.canceled == false)
        let other = try #require(URL(string: "https://other.test/favicon.ico"))
        let last = Task { await cache.image(other) }
        try await Task.sleep(for: .milliseconds(10))
        last.cancel()
        #expect(await last.value == nil)
        #expect(await loader.canceled)
        #expect(cache.cached(other) == nil)
        #expect(await cache.image(other) != nil, "Cancellation must allow a new row to retry immediately")
    }

    @Test func `canceled and unnormalized requests never start download`() async throws {
        let loader = BrowserFaviconTestLoader(data: nil)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, decode: Self.decodeImage)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(URL(string: "https://example.com/favicon.ico")!)
        }
        #expect(await canceled.value == nil)
        #expect(try await cache.image(#require(URL(string: "https://user:secret@example.com/private?q=token"))) == nil)
        #expect(await cache.image(URL(fileURLWithPath: "/private/site.html")) == nil)
        #expect(await loader.calls == 0)
    }

    @Test func `download uses short timeout size limit and handles offline failure`() async throws {
        let url = try #require(URL(string: "https://example.com/favicon.ico"))
        let transport = BrowserFaviconTestTransport()
        #expect(await AskBrowserFaviconCache.load(URL(string: "https://example.com/private?token=value")!, transport: transport) == nil)
        #expect(await transport.request == nil)
        #expect(await AskBrowserFaviconCache.load(url, transport: transport) == Data("icon".utf8))
        #expect(await transport.request?.url == url)
        #expect(await transport.request?.timeoutInterval == 3)
        #expect(await transport.limit == 262_144)
        #expect(await AskBrowserFaviconCache.load(url, transport: BrowserFaviconTestTransport(fails: true)) == nil)
    }

    @Test func `native icon renders cached image and fallback without changing row size`() async throws {
        _ = NSApplication.shared
        let data = try png(), url = try #require(URL(string: "https://example.com/favicon.ico"))
        let loader = BrowserFaviconTestLoader(data: data, delay: .milliseconds(30))
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, decode: Self.decodeImage)
        for site in try [url, #require(URL(string: "https://missing.test/favicon.ico"))] {
            let scope = AskImagePresentationScope()
            let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
            let view = NSHostingView(rootView: AskBrowserFaviconView(url: site, fallback: nil,
                                                                     symbol: "rectangle.on.rectangle", filled: true,
                                                                     cache: cache).environment(\.askContextImageAccess, access))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            #expect(view.fittingSize == NSSize(width: 28, height: 28))
            try await AskQuickSearchSessionTests.wait { cache.cached(site, access: access) != nil }
        }
    }
}
