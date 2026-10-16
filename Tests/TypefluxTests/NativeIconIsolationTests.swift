import AppKit
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class NativeIconBlock: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var started = 0
    var count: Int { lock.withLock { started } }
    func run() throws -> ManagedProcess.Result {
        lock.withLock { started += 1 }; gate.wait(); throw MediaFailure.unavailable
    }
}
private actor NativeIconCalls {
    var count = 0
    func called() { count += 1 }
}

@MainActor final class NativeIconIsolationTests: XCTestCase {
    private func request(_ icon: MediaNativeIcon = .init(kind: .type, value: "public.folder"), edge: Int = 56) -> MediaRequest {
        var request = MediaRequest(operation: .nativeIcon)
        request.icon = icon; request.preview = .init(width: edge, height: edge)
        return request
    }
    private func raster() -> CGImage {
        let context = CGContext(data: nil, width: 56, height: 56, bitsPerComponent: 8, bytesPerRow: 224,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 56, height: 56)); return context.makeImage()!
    }
    private func worker() throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/native-icon-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 3, run: { process, cancelled in
            var process = process; process.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
    }

    func testAllowlistAndBoundsRejectBeforeDispatch() async throws {
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid request dispatched"); throw MediaFailure.unavailable })
        for icon in [MediaNativeIcon(kind: .file, value: "relative"), .init(kind: .file, value: "/a\0b"),
                     .init(kind: .file, value: "/" + String(repeating: "x", count: 4096)), .init(kind: .type, value: ""),
                     .init(kind: .type, value: "public/folder"), .init(kind: .type, value: String(repeating: "x", count: 257))] {
            do { _ = try await AskFinderIcon.decode(icon, worker: worker); XCTFail("Invalid icon accepted") } catch {}
        }
        for edge in [0, 113, Int.max] {
            do { _ = try await AskFinderIcon.decode(.init(kind: .type, value: "public.folder"), edge: edge, worker: worker); XCTFail() } catch {}
        }
        for scale in [CGFloat.nan, .infinity, 0, -1, 5] {
            let image = await AskFinderIcon.image(for: URL(fileURLWithPath: "/tmp"), scale: scale, worker: MediaWorker(timeout: 3))
            XCTAssertNil(image)
        }
        let remote = await AskFinderIcon.image(for: URL(string: "https://example.test")!, worker: MediaWorker(timeout: 3)); XCTAssertNil(remote)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await AskFinderIcon.decode(.init(kind: .type, value: "public.folder"), worker: worker) }
        do { _ = try await cancelled.value; XCTFail() } catch {}
    }

    func testProtocolRejectsMixedRequestsAndWrongRasterIdentity() throws {
        var good = request(); try good.validate()
        for change in [ { (r: inout MediaRequest) in r.icon = nil }, { $0.operation = .previewImage },
                        { $0.preview?.width = 113 }, { $0.preview?.page = 1 }, { $0.preview?.passage = "text" },
                        { $0.preview?.start = 0 }, { $0.preview?.container = .mp4 }, { $0.preview?.imageType = .png }] {
            var bad = good; change(&bad); XCTAssertThrowsError(try bad.validate())
        }
        var response = MediaResponse(id: good.id); response.preview = .init(rasters: [.init(width: 56, height: 56)])
        try response.validate(for: good)
        response.id = UUID(); XCTAssertThrowsError(try response.validate(for: good)); response.id = good.id
        response.preview?.rasters[0].stride = 1; XCTAssertThrowsError(try response.validate(for: good))
        response.preview = .init(rasters: [.init(width: 57, height: 56)]); XCTAssertThrowsError(try response.validate(for: good))
        good.operation = .previewImage; good.icon = nil
        XCTAssertThrowsError(try MediaNativeIconDecoder.decode(good, directory: URL(fileURLWithPath: "/tmp")))
    }

    func testInjectedNativeAdapterRasterizesAtRequestedSizeAndFailsLocally() throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let good = request(edge: 28), image = NSImage(cgImage: raster(), size: .init(width: 1024, height: 1024))
        let result = try MediaNativeIconDecoder.decode(good, directory: root) { icon in
            XCTAssertEqual(icon.kind, .type); return image
        }
        try result.validate(for: good)
        XCTAssertEqual(result.preview?.rasters.first?.bytes, 28 * 28 * 4)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("raster-0")).count, 28 * 28 * 4)
        XCTAssertThrowsError(try MediaNativeIconDecoder.decode(good, directory: root) { _ in throw MediaFailure.unavailable })
        XCTAssertThrowsError(try MediaNativeIconDecoder.decode(good, directory: root) { _ in NSImage(size: .zero) })
        XCTAssertThrowsError(try MediaNativeIconDecoder.lookup(.init(kind: .type, value: "not-a-registered-type")))
    }

    func testRealHelperFileTypeFolderAndMissingFileUseRawPixels() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.txt"); try Data("private fixture".utf8).write(to: file)
        let worker = try worker()
        for icon in [MediaNativeIcon(kind: .file, value: root.path), .init(kind: .file, value: file.path),
                     .init(kind: .file, value: root.appendingPathComponent("missing.txt").path), .init(kind: .type, value: "public.folder")] {
            let result = try await AskFinderIcon.decode(icon, worker: worker)
            XCTAssertEqual(result.images.count, 1); XCTAssertEqual(result.images[0].width, 56)
            XCTAssertEqual(result.images[0].dataProvider?.data.map { CFDataGetLength($0) }, 56 * 56 * 4)
        }
        do { _ = try await AskFinderIcon.decode(.init(kind: .type, value: "not-a-registered-type"), worker: worker); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("private fixture".utf8))
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }

    func testAdmissionSurvivesUncooperativeCancellation() async throws {
        let block = NativeIconBlock(), icon = MediaNativeIcon(kind: .type, value: "public.folder")
        let worker = MediaWorker(run: { _, _ in try block.run() })
        let first = Task { try await AskFinderIcon.decode(icon, worker: worker) }
        let second = Task { try await AskFinderIcon.decode(icon, worker: worker) }
        for _ in 0..<200 where block.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(block.count, 2); first.cancel(); second.cancel()
        let third = Task { try await AskFinderIcon.decode(icon, worker: worker) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(block.count, 2); block.gate.signal(); block.gate.signal()
        _ = try? await first.value; _ = try? await second.value
        for _ in 0..<200 where block.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(block.count, 3)
        block.gate.signal(); _ = try? await third.value
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testCancelledQueuedIconNeverStarts() async throws {
        let admission = AskNativeIconAdmission(limit: 1)
        var first: AskNativeIconAdmission.Permit? = try await admission.acquire()
        let queued = Task { try await admission.acquire() }
        try await Task.sleep(for: .milliseconds(10))
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled request acquired a slot") }
        catch is CancellationError {}
        first = nil
        let next = try await admission.acquire()
        withExtendedLifetime(next) {}
    }

    func testLauncherCachesAndCoalescesApplicationIcons() async throws {
        let calls = NativeIconCalls(), pixels = raster()
        let cache = AskLauncherIconCache(decode: { _ in
            await calls.called()
            try await Task.sleep(for: .milliseconds(30))
            return .init(images: [pixels], numbers: [], pages: 0)
        })
        let icon = MediaNativeIcon(kind: .file, value: "/Applications/Fixture.app")
        async let first = cache.load(icon)
        async let second = cache.load(icon)
        _ = try await (first, second)
        let afterParallel = await calls.count
        XCTAssertEqual(afterParallel, 1)
        XCTAssertEqual(cache.cached(icon)?.images.first?.width, 56)
        _ = try await cache.load(icon)
        let afterCache = await calls.count
        XCTAssertEqual(afterCache, 1)
        cache.clear()
        XCTAssertNil(cache.cached(icon))
        XCTAssertFalse(AskLauncherIconCache.eligible(.init(kind: .file, value: "/private/secret.pdf")))
    }

    func testLauncherPrefetchesVersionedFilesAndFoldersAndClearsThemOnHide() async throws {
        let calls = NativeIconCalls(), pixels = raster(), revision = Date(timeIntervalSince1970: 1_000)
        let cache = AskLauncherIconCache(fileCapacity: 3, decode: { _ in
            await calls.called()
            return .init(images: [pixels], numbers: [], pages: 0)
        })
        let app = MediaNativeIcon(kind: .file, value: "/Applications/Fixture.app")
        let file = MediaNativeIcon(kind: .file, value: "/tmp/invoice.pdf")
        let folder = MediaNativeIcon(kind: .file, value: "/tmp/Receipts")
        let hits = [
            AskFileHit(path: file.value, name: "invoice.pdf", kind: .file, modified: revision, score: 1),
            AskFileHit(path: folder.value, name: "Receipts", kind: .folder, modified: revision, score: 0.9)
        ]
        _ = try await cache.load(app)
        cache.prefetchFiles(hits)
        for _ in 0..<100 where cache.cached(file, revision: revision) == nil ||
            cache.cached(folder, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(cache.cached(file, revision: revision))
        XCTAssertNotNil(cache.cached(folder, revision: revision))
        let prefetched = await calls.count
        XCTAssertEqual(prefetched, 3)
        _ = try await cache.load(file, revision: revision)
        let reused = await calls.count
        XCTAssertEqual(reused, 3)

        let changed = revision.addingTimeInterval(1)
        XCTAssertNil(cache.cached(file, revision: changed))
        _ = try await cache.load(file, revision: changed)
        let reloaded = await calls.count
        XCTAssertEqual(reloaded, 4)
        cache.clearFiles()
        XCTAssertNil(cache.cached(file, revision: changed))
        XCTAssertNil(cache.cached(folder, revision: revision))
        XCTAssertNotNil(cache.cached(app), "Application icons survive launcher sessions")
        XCTAssertFalse(AskLauncherIconCache.eligible(file, revision: nil))
        XCTAssertTrue(AskLauncherIconCache.eligible(file, revision: revision))
    }

    func testLauncherFileIconCacheHasSeparateSizeBound() async throws {
        let pixels = raster(), revision = Date(timeIntervalSince1970: 1_000)
        let cache = AskLauncherIconCache(fileCapacity: 1, decode: { _ in
            .init(images: [pixels], numbers: [], pages: 0)
        })
        let first = MediaNativeIcon(kind: .file, value: "/tmp/first.txt")
        let second = MediaNativeIcon(kind: .file, value: "/tmp/second.txt")
        _ = try await cache.load(first, revision: revision)
        _ = try await cache.load(second, revision: revision)
        XCTAssertNil(cache.cached(first, revision: revision))
        XCTAssertNotNil(cache.cached(second, revision: revision))
    }

    func testClosingLauncherDoesNotRepopulatePrivateIconCacheFromLateDecode() async throws {
        let pixels = raster(), revision = Date(timeIntervalSince1970: 1_000)
        let cache = AskLauncherIconCache(decode: { _ in
            try await Task.sleep(for: .milliseconds(100))
            return .init(images: [pixels], numbers: [], pages: 0)
        })
        let icon = MediaNativeIcon(kind: .file, value: "/tmp/private.txt")
        let loading = Task { try await cache.load(icon, revision: revision) }
        try await Task.sleep(for: .milliseconds(10))
        cache.clearFiles()
        do { _ = try await loading.value; XCTFail("Closed launcher accepted a late private icon") }
        catch is CancellationError {}
        XCTAssertNil(cache.cached(icon, revision: revision))
    }

    func testDefaultLegacyCacheDoesNotPrefetchOrCacheNativeIcons() async {
        let cache = AskResultImageCache(), key = AskResultImageCache.Key(url: URL(fileURLWithPath: "/missing.app"), thumbnail: false)
        cache.prefetch([key]); let first = await cache.image(key); XCTAssertNil(first); XCTAssertNil(cache.cached(key))
        var thumbnail = key; thumbnail.thumbnail = true
        let second = await cache.image(thumbnail); XCTAssertNil(second); XCTAssertNil(cache.cached(thumbnail))
        XCTAssertNil(AskPluginItemIcon.image(.fileType("public.folder")))
    }

    func testChildCrashAndHangFailOnceWithoutReplaying() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for script in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let executable = root.appendingPathComponent(UUID().uuidString)
            try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let worker = MediaWorker(executable: executable, timeout: 0.1), start = ContinuousClock.now
            do { _ = try await AskFinderIcon.decode(.init(kind: .type, value: "public.folder"), worker: worker); XCTFail() } catch {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        }
    }

    func testScopedViewRefreshesGenerationAndClearsOnRevocation() async throws {
        _ = NSApplication.shared
        let scope = AskImagePresentationScope(), calls = NativeIconCalls(), pixels = raster()
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        func content(_ generation: Int) -> some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Isolated native icons").foregroundColor(.black)
                HStack {
                    AskNativeIconView(icon: .init(kind: .file, value: "/fixture.app"), decode: { _ in
                        await calls.called(); return .init(images: [pixels], numbers: [], pages: 0)
                    }).frame(width: 56, height: 56)
                    Text("Finder pixels · scoped lifetime").foregroundColor(.black)
                }
            }.padding(24).frame(width: 370, height: 160).background(Color.white)
                .environment(\.askContextImageAccess, access).environment(\.askIconGeneration, generation)
        }
        let view = NSHostingView(rootView: content(1))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 370, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func capture() throws -> (NSBitmapImageRep, Int) {
            view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
            var blue = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) { for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.blueComponent > 0.7, color.redComponent < 0.3 { blue += 1 }
            } }
            return (rep, blue)
        }
        var ready: NSBitmapImageRep?
        for _ in 0..<200 {
            let (rep, blue) = try capture(); if blue > 200 { ready = rep; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/native-icon-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(ready?.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("native-icons.png"))
        view.rootView = content(2)
        for _ in 0..<200 { if await calls.count == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let count = await calls.count; XCTAssertEqual(count, 2)
        scope.invalidate()
        var cleared = false
        for _ in 0..<100 { if try capture().1 == 0 { cleared = true; break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cleared)
    }

    func testResultAndApplicationCallersKeepFallbackWithoutPermission() async throws {
        _ = NSApplication.shared
        let scope = AskImagePresentationScope()
        let denied = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { false })
        let url = URL(fileURLWithPath: "/private/fixture.app")
        let app = AskAppEntry(name: "Private fixture", url: url, bundleID: nil, names: [])
        let row = AskLauncherHome.Row(id: "fixture", title: "Fixture", symbol: "app", tint: .neutral, action: .application(app))
        let before = MediaWorker.previews.activeCount
        let view = NSHostingView(rootView: VStack {
            AskPluginItemIcon(icon: .fileType("public.folder"), symbol: "folder", filled: false)
            AskPluginItemIcon(icon: .fileIcon(url), symbol: "app", filled: false)
            AskFileIconView(url: url, thumbnail: true)
            AskLauncherSuggestions(sections: [.applications(rows: [row])], highlighted: .constant(0), onPick: { _ in XCTFail("Icon inspection executed an action") })
        }.frame(width: 400, height: 220).environment(\.askContextImageAccess, denied))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 400, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(MediaWorker.previews.activeCount, before)
        XCTAssertNotNil(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    }
}
