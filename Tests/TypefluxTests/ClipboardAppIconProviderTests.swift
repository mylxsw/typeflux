import AppKit
import SwiftUI
import TypefluxMediaProtocol
import XCTest
@testable import Typeflux

private actor SourceIconCalls {
    var values: [MediaNativeIcon] = []
    func append(_ value: MediaNativeIcon) { values.append(value) }
}
private actor SourceIconPending {
    var continuation: CheckedContinuation<AskFilePreviewPDF.Result, Error>?
    func read() async throws -> AskFilePreviewPDF.Result { try await withCheckedThrowingContinuation { continuation = $0 } }
    var started: Bool { continuation != nil }
    func finish(_ value: AskFilePreviewPDF.Result) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor final class ClipboardAppIconProviderTests: XCTestCase {
    private func result() -> AskFilePreviewPDF.Result {
        let context = CGContext(data: nil, width: 56, height: 56, bitsPerComponent: 8, bytesPerRow: 224,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 56, height: 56))
        return .init(images: [context.makeImage()!], numbers: [], pages: 0)
    }
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/source-icon-validation")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func window() -> SettingsImageWindow {
        _ = NSApplication.shared
        let window = SettingsImageWindow(contentRect: .init(x: 100, y: 100, width: 580, height: 420),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); return window
    }
    func testDescriptorsPreserveSourceAndRejectMalformedIDsWithoutDiscovery() throws {
        let entry = ClipboardTestSupport.entry(.text, sourceBundleID: "fixture.source", sourceAppName: "Source")
        XCTAssertEqual(ClipboardAppIconProvider.target(for: entry), .init(kind: .application, value: "fixture.source"))
        XCTAssertNil(ClipboardAppIconProvider.target(for: ClipboardTestSupport.entry(.image)))
        for id in ["", "../application", "file:///app", "com.app\0secret", "日本語", String(repeating: "a", count: 257)] {
            XCTAssertNil(ClipboardAppIconProvider.target(bundleID: id))
        }
        XCTAssertNotNil(ClipboardAppIconProvider.target(bundleID: String(repeating: "a", count: 256)))
        XCTAssertEqual(ClipboardAppIconProvider.target(for: ClipboardTestSupport.entry(.voice))?.value, "ai.gulu.app.typeflux")
        let directory = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Private.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fixture.unregistered", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(ClipboardAppIconProvider.target(for: ClipboardTestSupport.entry(.voice), ownBundle: bundle),
            .init(kind: .file, value: bundle.bundleURL.path))
    }
    func testBrowserDescriptorsKeepActionsAndOriginWithoutHostDiscovery() throws {
        var entry = AskBrowserSearchEntry(id: "tab", kind: .tab, browser: .chrome, title: "Site", url: "https://user:secret@example.test/private?q=token",
            target: .init(browser: .chrome, windowID: "1", tabID: "2", index: 1, url: "https://example.test"))
        let tab = entry.item(settings: .init())
        XCTAssertEqual(tab.icon, .websiteIcon(URL(string: "https://example.test/favicon.ico")!, fallback: nil, application: entry.browser.bundleID))
        XCTAssertEqual(tab.actions.count, 2)
        entry.kind = .bookmark; entry.target = nil
        XCTAssertEqual(entry.item(settings: .init()).icon, .application(entry.browser.bundleID))
        XCTAssertNil(AskPluginItemIcon.image(.application(entry.browser.bundleID)))
        entry.url = "javascript:alert(1)"
        XCTAssertFalse(entry.item(settings: .init()).valid)
    }
    func testRealHelperFinderAndMissingSourceFailWithoutApplicationLaunch() async throws {
        let folder = try folder()
        let worker = MediaWorker(run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let target = try XCTUnwrap(ClipboardAppIconProvider.target(bundleID: "com.apple.finder"))
        let pixels = try await AskFinderIcon.decode(target, worker: worker)
        XCTAssertEqual(pixels.images.first?.width, 56)
        do { _ = try await AskFinderIcon.decode(.init(kind: .application, value: "fixture.absent.source.application"), worker: worker); XCTFail() } catch {}
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }
    func testNativeWindowHideCloseMiniaturizeAndAccountChangesRetirePixels() async throws {
        let window = window(), raster = result()
        defer { window.close() }
        let model = AskContextImageModel(maximumEdge: 56, decode: { _ in raster })
        XCTAssertFalse(window.images.access.allows())
        window.makeKeyAndOrderFront(nil)
        let first = window.images.access
        await model.load("source", access: first); XCTAssertNotNil(model.image)
        window.orderOut(nil); XCTAssertNil(model.image); XCTAssertFalse(first.allows())
        window.orderFront(nil); await model.load("source", access: window.images.access)
        XCTAssertNotNil(model.image)
        window.miniaturize(nil); XCTAssertNil(model.image)
        window.deminiaturize(nil); XCTAssertTrue(window.images.access.allows())
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            window.orderFront(nil); let old = window.images.access
            await model.load("source", access: old)
            NotificationCenter.default.post(name: name, object: nil)
            XCTAssertNil(model.image); XCTAssertFalse(old.allows())
        }
        window.orderFront(nil); await model.load("source", access: window.images.access)
        window.close(); XCTAssertNil(model.image)
    }
    func testLateResultAndOldAccessCannotPopulateReopenedWindow() async throws {
        let window = window(), pending = SourceIconPending(), pixels = result(), budget = AskToolPixelBudget(limit: 56 * 56 * 4)
        defer { window.close() }
        window.orderFront(nil)
        let old = window.images.access
        let model = AskContextImageModel(budget: budget, maximumEdge: 56, decode: { _ in try await pending.read() })
        let task = Task { await model.load("source", access: old) }
        for _ in 0..<100 { if await pending.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let started = await pending.started; XCTAssertTrue(started)
        window.orderOut(nil); window.orderFront(nil)
        XCTAssertThrowsError(try budget.acquire(bytes: 1), "Uncooperative work retains its pixel reservation")
        await pending.finish(pixels); await task.value
        XCTAssertNil(model.image); XCTAssertNil(model.displayed("source", access: window.images.access))
        XCTAssertNoThrow(try budget.acquire(bytes: 1))
        await model.load("old", access: old); XCTAssertNil(model.image)
    }
    func testSessionReleaseRetiresDisplayedPixels() async throws {
        var session: SettingsImageSession? = SettingsImageSession()
        session?.setVisible(true)
        let access = try XCTUnwrap(session?.access), pixels = result()
        let model = AskContextImageModel(maximumEdge: 56, decode: { _ in pixels })
        await model.load("source", access: access)
        session = nil
        for _ in 0..<100 { if model.image == nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.image); XCTAssertFalse(access.allows())
    }
    func testSourceSettingsAndBrowserViewsDisplayRawPixelsAndClearOnHide() async throws {
        let window = window(), pixels = result(), calls = SourceIconCalls()
        window.setContentSize(.init(width: 580, height: 480))
        let suite = "SourceIconUI.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); window.contentView = nil; window.close() }
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardIgnoredApps = [.init(bundleID: "fixture.ignored", name: "Ignored application")]
        let history = InMemoryClipboardHistoryStore()
        history.record(.text("private"), source: ClipboardSource(bundleID: "fixture.usage", appName: "Source application"), at: Date())
        let model = ClipboardSettingsModel(store: settings, history: history); model.reloadUsage()
        let content = VStack(alignment: .leading, spacing: 18) {
            Text("Source application icons").font(.title2).foregroundStyle(.black)
            HStack {
                ClipboardEntryLeadingIcon(entry: ClipboardTestSupport.entry(.text, sourceBundleID: "fixture.clipboard"))
                Text("Clipboard source").foregroundStyle(.black)
                AskPluginItemIcon(icon: .application("fixture.browser"), symbol: "bookmark", filled: false)
                Text("Browser application").foregroundStyle(.black)
            }
            ClipboardIgnoredAppsSection(model: model)
            ClipboardUsageSection(model: model)
        }.padding(24).frame(width: 580, height: 480).background(.white)
            .environment(\.askNativeIconDecoder, { icon in await calls.append(icon); return pixels })
        let view = NSHostingView(rootView: SettingsImageContent(session: window.images, content: content))
        window.contentView = view; window.orderFront(nil)
        func capture() throws -> (NSBitmapImageRep, Int) {
            view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var colored = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) { for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent - c.greenComponent > 0.3, c.blueComponent - c.greenComponent > 0.3 { colored += 1 }
            } }
            return (rep, colored)
        }
        for _ in 0..<200 { if try capture().1 > 90 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let snapshot = try capture(), values = await calls.values
        XCTAssertEqual(Set(values.map(\.value)), ["fixture.clipboard", "fixture.browser", "fixture.ignored", "fixture.usage"])
        XCTAssertGreaterThan(snapshot.1, 90)
        try XCTUnwrap(snapshot.0.representation(using: .png, properties: [:])).write(to: folder().appendingPathComponent("source-app-icons.png"))
        window.orderOut(nil)
        for _ in 0..<100 { if try capture().1 == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try capture().1, 0)
    }
    func testBrowserSettingsRevocationStopsFallbackLookupAndLatePixels() async throws {
        let window = window(), calls = SourceIconCalls(), pixels = result()
        defer { window.contentView = nil; window.close() }
        let cache = AskBrowserFaviconCache(loader: { _ in nil })
        func content(_ fallback: URL?, _ application: String?) -> some View {
            AskBrowserFaviconView(url: URL(string: "https://example.test/favicon.ico")!, fallback: fallback,
                application: application, symbol: "bookmark", filled: false, cache: cache)
                .environment(\.askNativeIconDecoder, { icon in await calls.append(icon); return pixels })
        }
        let view = NSHostingView(rootView: SettingsImageContent(session: window.images, content: content(nil, "fixture.browser")))
        window.contentView = view; window.orderFront(nil)
        let targets: [MediaNativeIcon] = [.init(kind: .application, value: "fixture.browser"),
            .init(kind: .application, value: "fixture.other.browser"), .init(kind: .file, value: "/private/fixture.app")]
        for (index, target) in targets.enumerated() {
            if index > 0 {
                view.rootView = SettingsImageContent(session: window.images,
                    content: content(target.kind == .file ? URL(fileURLWithPath: target.value) : nil,
                                     target.kind == .application ? target.value : nil))
            }
            for _ in 0..<100 { if await calls.values.count >= index + 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
            let values = await calls.values
            XCTAssertEqual(values, Array(targets.prefix(index + 1)), "Changing the browser at the same origin must replace its fallback once")
        }
        let before = await calls.values
        NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: nil)
        for _ in 0..<10 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(5)) }
        let after = await calls.values; XCTAssertEqual(after, before)
        XCTAssertEqual(window.images.scope.visible, true, "Only the withdrawn browser row is retired")
    }
    func testDeniedSourceNeverDispatchesOrRetriesOnRecomputation() async throws {
        let window = window(), calls = SourceIconCalls(), pixels = result()
        defer { window.contentView = nil; window.close() }
        let view = NSHostingView(rootView: ClipboardEntryLeadingIcon(entry: ClipboardTestSupport.entry(.text, sourceBundleID: "private.source"))
            .environment(\.askNativeIconDecoder, { icon in await calls.append(icon); return pixels }).frame(width: 60, height: 60))
        window.contentView = view; window.orderFront(nil)
        for _ in 0..<10 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(5)) }
        let values = await calls.values; XCTAssertTrue(values.isEmpty)
    }
}
