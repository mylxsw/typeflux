import AppKit
import Darwin
import SwiftUI
import TypefluxMediaProtocol
import XCTest
@testable import Typeflux

private actor SmallIconGate {
    var calls = 0
    var waiting: [CheckedContinuation<Data?, Never>] = []
    func load() async -> Data? { calls += 1; return await withCheckedContinuation { waiting.append($0) } }
    func release(_ data: Data?) { let old = waiting; waiting = []; old.forEach { $0.resume(returning: data) } }
}
private final class SmallIconBlocking: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func run() throws -> ManagedProcess.Result {
        lock.lock(); calls += 1; lock.unlock()
        release.wait(); throw CancellationError()
    }
}
@MainActor private final class SmallIconAccess { var allowed = true }

@MainActor final class SmallIconIsolationTests: XCTestCase {
    private func png(red: Bool = false) -> Data {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 32, height: 32))
        return AskAttachmentFixture.encode(context.makeImage()!, type: .png)
    }
    private func ico(_ png: Data) -> Data {
        var data = Data([0,0,1,0,1,0,32,32,0,0,1,0,32,0])
        for value in [UInt32(png.count), 22] { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(png); return data
    }
    private func wait(_ gate: SmallIconGate, count: Int = 1) async throws {
        for _ in 0..<200 { if await gate.calls >= count { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Loader did not start")
    }
    private func raster(_ red: Bool = false) -> CGImage { AskAttachmentFixture.image(width: 32, height: red ? 31 : 32) }

    func testRealHelperDecodesPNGICOAndFreshFileBytesWithoutPathCache() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/icon-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let worker = MediaWorker(run: { process, cancelled in
            var process = process; process.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        for data in [png(), ico(png())] {
            let image = try await AskSmallIconDecoder.decode(.data(data), worker: worker)
            XCTAssertEqual(image.width, 32); XCTAssertEqual(image.height, 32)
        }
        let file = root.appendingPathComponent("icon.png"); try png().write(to: file)
        let old = try await AskSmallIconDecoder.decode(.file(file), worker: worker)
        try png(red: true).write(to: file)
        let fresh = try await AskSmallIconDecoder.decode(.file(file), worker: worker)
        XCTAssertNotEqual(old.dataProvider?.data as Data?, fresh.dataProvider?.data as Data?)
        for data in [Data([1,2,3]), Data(png().prefix(20)), Data(ico(png()).prefix(22))] {
            do { _ = try await AskSmallIconDecoder.decode(.data(data), worker: worker); XCTFail("Malformed icon accepted") } catch {}
        }
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }

    func testInputAndOutputLimitsRefuseBeforeNativeWork() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid input dispatched"); throw MediaFailure.unavailable })
        let file = root.appendingPathComponent("oversized"); FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(AskSmallIconDecoder.fileLimit + 1)); try handle.close()
        let fifo = root.appendingPathComponent("fifo"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for input in [AskSmallIconDecoder.Input.data(Data()), .data(Data(count: 262_145)), .file(file), .file(fifo), .file(root.appendingPathComponent("missing")), .file(URL(string: "https://example.test/image")!)] {
            do { _ = try await AskSmallIconDecoder.decode(input, worker: worker); XCTFail("Unbounded input accepted") } catch {}
        }
        for edge in [0, 1601, Int.max] {
            XCTAssertThrowsError(try MediaPreviewDisplay.renderImage(Data(), type: nil, cancellation: AskSearchCancellation(), worker: worker, edge: edge))
        }
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await AskSmallIconDecoder.decode(.data(Data()), worker: worker) }
        do { _ = try await task.value; XCTFail("Cancelled call accepted") } catch {}
    }

    func testDecoderAdmissionRetainsCancelledNativeWorkUntilReturn() async throws {
        let block = SmallIconBlocking(), bytes = png()
        let worker = MediaWorker(run: { _, _ in try block.run() })
        let first = Task { try await AskSmallIconDecoder.decode(.data(bytes), worker: worker) }
        let second = Task { try await AskSmallIconDecoder.decode(.data(bytes), worker: worker) }
        for _ in 0..<200 where block.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(block.count, 2); first.cancel(); second.cancel()
        do { _ = try await AskSmallIconDecoder.decode(.data(bytes), worker: worker); XCTFail("Third decoder admitted") } catch {}
        XCTAssertEqual(block.count, 2)
        block.release.signal(); block.release.signal()
        do { _ = try await first.value; XCTFail("Cancelled result published") } catch {}
        do { _ = try await second.value; XCTFail("Cancelled result published") } catch {}
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }

    func testCancelledDownloadsRetainAdmissionUntilUncooperativeCompletion() async throws {
        let gate = SmallIconGate(), image = raster()
        let cache = AskBrowserFaviconCache(loader: { _ in await gate.load() }, decode: { _ in image })
        let one = URL(string: "https://one.test/favicon.ico")!, two = URL(string: "https://two.test/favicon.ico")!, three = URL(string: "https://three.test/favicon.ico")!
        let first = Task { await cache.image(one) }, second = Task { await cache.image(two) }
        try await wait(gate, count: 2); first.cancel(); second.cancel(); cache.cancel()
        let refused = await cache.image(three); XCTAssertNil(refused)
        let count = await gate.calls; XCTAssertEqual(count, 2)
        await gate.release(Data([1])); let a = await first.value, b = await second.value
        XCTAssertNil(a); XCTAssertNil(b); XCTAssertNil(cache.cached(one))
        let next = Task { await cache.image(three) }; try await wait(gate, count: 3)
        await gate.release(Data([1])); let value = await next.value; XCTAssertNotNil(value)
        cache.cancel()
    }

    func testSharedWaitersAreBoundedAndOneCancellationDoesNotCancelOthers() async throws {
        let gate = SmallIconGate(), image = raster(), url = URL(string: "https://shared.test/favicon.ico")!
        let cache = AskBrowserFaviconCache(loader: { _ in await gate.load() }, decode: { _ in image })
        let tasks = (0..<16).map { _ in Task { await cache.image(url) } }
        try await wait(gate); try await Task.sleep(for: .milliseconds(30))
        let overflow = await cache.image(url); XCTAssertNil(overflow)
        tasks[0].cancel(); await gate.release(Data([1]))
        for (index, task) in tasks.enumerated() { let value = await task.value; if index == 0 { XCTAssertNil(value) } else { XCTAssertTrue(value === image) } }
        let count = await gate.calls; XCTAssertEqual(count, 1); cache.cancel()
    }

    func testScopeInvalidationAndFreshAuthorizationCannotBlessOldCache() async throws {
        let permission = SmallIconAccess(), scope = AskImagePresentationScope(), image = raster()
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { permission.allowed })
        var loads = 0
        let cache = AskBrowserFaviconCache(loader: { _ in await MainActor.run { loads += 1; return Data([1]) } }, decode: { _ in image })
        let url = URL(string: "https://private.test/favicon.ico")!
        let first = await cache.image(url, access: access); XCTAssertNotNil(first)
        permission.allowed = false
        XCTAssertNil(cache.cached(url, access: .init(scope: scope, epoch: scope.epoch, authorize: { true })))
        let denied = await cache.image(url, access: access); XCTAssertNil(denied)
        permission.allowed = true
        let fresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        _ = await cache.image(url, access: fresh); XCTAssertEqual(loads, 2)
        scope.invalidate(); XCTAssertNil(cache.cached(url, access: fresh))
        let unscoped = cache.cached(url); XCTAssertNil(unscoped)
    }

    func testRevocationDuringDecodeRejectsLatePixels() async throws {
        let gate = SmallIconGate(), scope = AskImagePresentationScope(), image = raster()
        let cache = AskBrowserFaviconCache(loader: { _ in Data([1]) }, decode: { _ in _ = await gate.load(); return image })
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let url = URL(string: "https://private.test/favicon.ico")!
        let task = Task { await cache.image(url, access: access) }; try await wait(gate)
        scope.setVisible(false); await gate.release(nil)
        let result = await task.value; XCTAssertNil(result); XCTAssertNil(cache.cached(url))
    }

    func testCacheHasStrictCapacityAndNeverCachesOversizedDecoderResults() async throws {
        let small = raster(), oversized = AskAttachmentFixture.image(width: 57, height: 1)
        let cache = AskBrowserFaviconCache(loader: { _ in Data([1]) }, decode: { _ in small })
        for n in 0..<129 { _ = await cache.image(URL(string: "https://host-\(n).test/favicon.ico")!) }
        XCTAssertNil(cache.cached(URL(string: "https://host-0.test/favicon.ico")!))
        XCTAssertNotNil(cache.cached(URL(string: "https://host-128.test/favicon.ico")!))
        let invalid = AskBrowserFaviconCache(loader: { _ in Data([1]) }, decode: { _ in oversized })
        let url = URL(string: "https://invalid.test/favicon.ico")!
        let result = await invalid.image(url); XCTAssertNil(result); XCTAssertNil(invalid.cached(url))
        cache.cancel(); invalid.cancel()
    }

    func testSmallPixelBudgetIsReservedBeforeDecodeAndReleasedOnRevocation() async throws {
        let gate = SmallIconGate(), scope = AskImagePresentationScope(), budget = AskToolPixelBudget(limit: 56 * 56 * 4)
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true }), image = raster()
        let first = AskContextImageModel(budget: budget, maximumEdge: 56, decode: { _ in _ = await gate.load(); return .init(images: [image], numbers: [], pages: 0) })
        let task = Task { await first.load("one", access: access) }; try await wait(gate)
        let second = AskContextImageModel(budget: budget, maximumEdge: 56, decode: { _ in XCTFail("Overbudget decode"); throw MediaFailure.unavailable })
        await second.load("two", access: access); XCTAssertTrue(second.unavailable)
        scope.invalidate(); await gate.release(nil); await task.value
        XCTAssertNil(first.image)
        let lease = try budget.acquire(bytes: 56 * 56 * 4); withExtendedLifetime(lease) {}
    }
    func testFileAndFaviconViewsShowPixelsRefreshIdentityAndClearPrivateDisplay() async throws {
        _ = NSApplication.shared
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("icon.png"); try png().write(to: file)
        let scope = AskImagePresentationScope(), access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let bytes = ico(png()), cache = AskBrowserFaviconCache(loader: { _ in bytes }, decode: { try await AskSmallIconDecoder.decode(.data($0), worker: MediaWorker(timeout: 3)) })
        let url = URL(string: "https://synthetic.test/favicon.ico")!
        func content(_ generation: Int) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Isolated optional icons").font(.headline).foregroundColor(.black)
                HStack(spacing: 12) {
                    AskPluginItemIcon(icon: .image(file), symbol: "doc", filled: false)
                        .environment(\.askSmallIconDecoder, { try await AskSmallIconDecoder.decode(.file($0), worker: MediaWorker(timeout: 3)) })
                    Text("Workflow file icon").foregroundColor(.black)
                }
                HStack(spacing: 12) {
                    AskBrowserFaviconView(url: url, fallback: nil, symbol: "globe", filled: false, cache: cache)
                    Text("Origin favicon · no live request").foregroundColor(.black)
                }
            }.padding(24).frame(width: 360, height: 180).background(Color.white)
                .environment(\.askContextImageAccess, access).environment(\.askIconGeneration, generation)
        }
        let view = NSHostingView(rootView: content(1))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 360, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close(); cache.cancel() }
        func frame() throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap
        }
        func colors(_ bitmap: NSBitmapImageRep) -> (blue: Int, red: Int) {
            var blue = 0, red = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.blueComponent > 0.7, color.redComponent < 0.3 { blue += 1 }
                    if color.redComponent > 0.7, color.blueComponent < 0.3 { red += 1 }
                }
            }
            return (blue, red)
        }
        var captured: NSBitmapImageRep?
        for _ in 0..<200 {
            let bitmap = try frame()
            if colors(bitmap).blue > 110 { captured = bitmap; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/icon-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(captured?.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("icons.png"))
        try png(red: true).write(to: file); view.rootView = content(2)
        var refreshed = false
        for _ in 0..<200 {
            if colors(try frame()).red > 50 { refreshed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(refreshed, "Same URL must be re-read for a new result generation")
        NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: nil)
        var withheld = false
        for _ in 0..<100 {
            let count = colors(try frame())
            if count.blue == 0, count.red > 50 { withheld = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(withheld); XCTAssertNil(cache.cached(url))
        scope.invalidate()
        var cleared = false
        for _ in 0..<100 {
            let count = colors(try frame())
            if count.blue == 0, count.red == 0 { cleared = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cleared); XCTAssertNil(cache.cached(url))
    }

    func testEditorLocalIconScopeLoadsAndCancelsOnRemoval() async throws {
        _ = NSApplication.shared
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("icon.png"); try png().write(to: file)
        let view = NSHostingView(rootView: AskLocalIconScope {
            AskSmallFileIcon(url: file, symbol: "doc")
        }.frame(width: 64, height: 64).background(Color.white))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 64, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var ready = false
        for _ in 0..<200 {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            if let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), color.blueComponent > 0.7, color.redComponent < 0.3 { ready = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready)
        window.contentView = nil
    }

}
