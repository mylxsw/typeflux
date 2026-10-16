import AppKit
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class QuickLookBlock: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var started = 0
    var count: Int { lock.withLock { started } }
    func run() throws -> ManagedProcess.Result { lock.withLock { started += 1 }; gate.wait(); throw MediaFailure.unavailable }
}
private actor QuickLookCalls {
    var count = 0
    func call() { count += 1 }
}

@MainActor final class QuickLookIsolationTests: XCTestCase {
    private func root() throws -> URL { try AskAttachmentFixture.directory() }
    private func image() -> CGImage {
        let context = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 120, height: 60))
        return context.makeImage()!
    }
    private func request(_ url: URL) -> MediaRequest {
        var request = MediaRequest(operation: .quickLook)
        request.quickLook = .init(path: url.path, representation: .thumbnail)
        request.preview = .init(width: 80, height: 80)
        return request
    }
    private func file(_ root: URL, name: String = "fixture.png") throws -> URL {
        let url = root.appendingPathComponent(name)
        try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 120, height: 60), type: .png).write(to: url)
        return url
    }
    private func worker() throws -> MediaWorker {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/quicklook-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MediaWorker(timeout: 3, run: { process, cancelled in
            var process = process; process.environment["LLVM_PROFILE_FILE"] = directory.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
    }

    func testProtocolRejectsPathsMixedOperationsAndMalformedRasters() throws {
        let good = request(URL(fileURLWithPath: "/private/fixture.png")); try good.validate()
        for path in ["", "relative", "https://example.test", "/a\0b", "/" + String(repeating: "a", count: 4096)] {
            var bad = good; bad.quickLook?.path = path; XCTAssertThrowsError(try bad.validate())
        }
        for change in [{ (r: inout MediaRequest) in r.quickLook = nil }, { $0.operation = .previewImage },
                       { $0.preview = nil }, { $0.preview?.page = 1 }, { $0.preview?.passage = "x" },
                       { $0.preview?.container = .mp4 }, { $0.preview?.start = 0 }, { $0.preview?.imageType = .png },
                       { $0.icon = .init(kind: .file, value: "/x") }, { $0.preview?.width = Int.max }] {
            var bad = good; change(&bad); XCTAssertThrowsError(try bad.validate())
        }
        var response = MediaResponse(id: good.id); response.preview = .init(rasters: [.init(width: 80, height: 40)])
        try response.validate(for: good)
        response.preview?.rasters[0].bytes += 1; XCTAssertThrowsError(try response.validate(for: good))
        response.preview = .init(rasters: [.init(width: 80, height: 40, page: 1)])
        XCTAssertThrowsError(try response.validate(for: good))
    }

    func testChildFitsPixelsAndRejectsFilesChangedDuringNativeWork() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try file(root), request = request(input), image = image()
        let response = try await MediaQuickLookDecoder.decode(request, directory: root) { url, options, kind in
            XCTAssertEqual(url.path, input.path); XCTAssertEqual(options.width, 80); XCTAssertEqual(kind, .thumbnail)
            return image
        }
        XCTAssertEqual(response.preview?.rasters.first?.width, 80)
        XCTAssertEqual(response.preview?.rasters.first?.height, 40)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("raster-0")).count, 80 * 40 * 4)
        do {
            _ = try await MediaQuickLookDecoder.decode(request, directory: root) { _, _, _ in
                try Data("changed".utf8).write(to: input); return image
            }; XCTFail("Changed original accepted")
        } catch { XCTAssertEqual(error as? MediaFailure, .unreadable) }
        var wrong = request; wrong.operation = .previewImage; wrong.quickLook = nil
        do { _ = try await MediaQuickLookDecoder.decode(wrong, directory: root); XCTFail() } catch {}
    }

    func testNativeFailureAndCancellationNeverProduceRaster() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try file(root), request = request(input), image = image()
        do { _ = try await MediaQuickLookDecoder.decode(request, directory: root) { _, _, _ in throw MediaFailure.unavailable }; XCTFail() } catch {}
        let task = Task {
            try await MediaQuickLookDecoder.decode(request, directory: root) { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }; return image
            }
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("raster-0").path))
    }

    func testInputBudgetsRejectSparseOversizeSpecialFilesAndUnboundedPackages() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let huge = root.appendingPathComponent("huge.png")
        let fd = open(huge.path, O_CREAT | O_RDWR, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, MediaQuickLook.maximumBytes + 1), 0); close(fd)
        let fifo = root.appendingPathComponent("pipe.png"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let package = root.appendingPathComponent("fixture.rtfd"); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let target = try file(root)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("link"), withDestinationURL: target)
        for url in [huge, fifo, root, package, root.appendingPathComponent("missing")] {
            do {
                _ = try await MediaQuickLookDecoder.decode(request(url), directory: root) { _, _, _ in XCTFail("Rejected input reached provider"); throw MediaFailure.unavailable }
                XCTFail("Input accepted")
            } catch {}
        }
        try FileManager.default.removeItem(at: package.appendingPathComponent("link"))
        for index in 0..<MediaQuickLook.maximumEntries { try Data().write(to: package.appendingPathComponent("f\(index)")) }
        do { _ = try await MediaQuickLookDecoder.decode(request(package), directory: root) { _, _, _ in XCTFail(); throw MediaFailure.unavailable }; XCTFail() } catch {}
    }

    func testBoundedPackageAndRootSymlinkKeepOriginalProviderContext() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("fixture.rtfd"); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        _ = try file(package, name: "embedded.png")
        let alias = root.appendingPathComponent("alias.rtfd"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: package)
        let image = image()
        _ = try await MediaQuickLookDecoder.decode(request(alias), directory: root) { url, _, _ in
            XCTAssertEqual(url, alias); return image
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("embedded.png").path))
    }

    func testHostRefusesInvalidDimensionsAndCancellationBeforeDispatch() async throws {
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid request dispatched"); throw MediaFailure.unavailable })
        for pixels in [CGSize.zero, .init(width: CGFloat.nan, height: 1), .init(width: CGFloat.infinity, height: 1),
                       .init(width: 4097, height: 1), .init(width: 4096, height: 4096)] {
            do { _ = try await AskQuickLookThumbnail.decode(URL(fileURLWithPath: "/x"), pixels: pixels, worker: worker); XCTFail() } catch {}
        }
        do { _ = try await AskQuickLookThumbnail.decode(URL(string: "https://example.test")!, pixels: .init(width: 10, height: 10), worker: worker); XCTFail() } catch {}
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await AskQuickLookThumbnail.decode(URL(fileURLWithPath: "/x"), pixels: .init(width: 10, height: 10), worker: worker) }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancelledWorkKeepsAdmissionUntilActualReturn() async throws {
        let block = QuickLookBlock(), worker = MediaWorker(run: { _, _ in try block.run() }), url = URL(fileURLWithPath: "/fixture")
        let first = Task { try await AskQuickLookThumbnail.decode(url, pixels: .init(width: 20, height: 20), worker: worker) }
        let second = Task { try await AskQuickLookThumbnail.decode(url, pixels: .init(width: 20, height: 20), worker: worker) }
        for _ in 0..<200 where block.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(block.count, 2); first.cancel(); second.cancel()
        do { _ = try await AskQuickLookThumbnail.decode(url, pixels: .init(width: 20, height: 20), worker: worker); XCTFail() } catch {}
        XCTAssertEqual(block.count, 2); block.gate.signal(); block.gate.signal()
        _ = try? await first.value; _ = try? await second.value
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testCrashAndHangRetireWithoutReplayingOrRemovingOriginal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try file(root), original = try Data(contentsOf: input)
        for script in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let executable = root.appendingPathComponent(UUID().uuidString)
            try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let worker = MediaWorker(executable: executable, timeout: 0.1), start = ContinuousClock.now
            do { _ = try await AskQuickLookThumbnail.decode(input, pixels: .init(width: 56, height: 56), worker: worker); XCTFail() } catch {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(2)); await worker.shutdown()
            XCTAssertEqual(worker.activeCount, 0); XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testRealHelperAndDocumentRendererReturnOnlyOwnedPixels() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try file(root), original = try Data(contentsOf: input), worker = try worker()
        let result = try await AskQuickLookThumbnail.decode(input, pixels: .init(width: 112, height: 112), iconFallback: true, worker: worker)
        let image = try XCTUnwrap(result.images.first)
        XCTAssertLessThanOrEqual(image.width, 112); XCTAssertLessThanOrEqual(image.height, 112)
        XCTAssertEqual(worker.activeCount, 0); XCTAssertEqual(try Data(contentsOf: input), original)
        var hit = previewHit("fixture.png"); hit.path = input.path
        let document = try await AskFilePreviewRenderer.generate(hit, kind: .document, pixels: .init(width: 120, height: 80), info: .init())
        XCTAssertEqual(document.kind, .document); XCTAssertEqual(document.images.count, 1)
        await worker.shutdown()
    }

    func testProductionLegacyCacheDoesNotStartThumbnailPrefetch() async {
        let cache = AskResultImageCache()
        let keys = (0..<1000).map { AskResultImageCache.Key(url: URL(fileURLWithPath: "/missing\($0).png"), thumbnail: true) }
        cache.prefetch(keys)
        let value = await cache.image(keys[0]); XCTAssertNil(value); XCTAssertNil(cache.cached(keys[0]))
    }

    func testPanelRetirementPurgesCachedPixelsAndDoesNotBlessOldScope() async throws {
        let clock = PreviewTestClock(), scope = AskImagePresentationScope()
        var generated = 0
        let loader = AskFilePreviewLoader(metadata: { _, _ in .init(fileSize: 1, modified: .distantPast) },
            generate: { _, kind, _, _ in generated += 1; return .init(kind: kind, text: "private") }, clock: clock)
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        controller.request(previewHit("file.docx"), access: access); clock.advance(0.12)
        for _ in 0..<100 where controller.state.content == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(loader.cacheCount, 1); XCTAssertEqual(generated, 1)
        scope.invalidate()
        XCTAssertNil(controller.state.content); XCTAssertEqual(loader.cacheCount, 0); XCTAssertEqual(loader.cacheCost, 0)
        controller.request(previewHit("file.docx"), access: access); clock.advance(0.12)
        XCTAssertEqual(generated, 1)
        let next = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        controller.request(previewHit("file.docx"), access: next); clock.advance(0.12)
        for _ in 0..<100 where controller.state.content == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(generated, 2); XCTAssertEqual(loader.cacheCount, 1)
        controller.dismissNow(); XCTAssertEqual(loader.cacheCount, 0); XCTAssertNil(controller.state.content)
    }

    func testVisibleThumbnailTracksRevisionAndClearsWhenScopeRevoked() async throws {
        _ = NSApplication.shared
        let scope = AskImagePresentationScope(), calls = QuickLookCalls(), pixels = image()
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        func content(_ revision: Double) -> some View {
            HStack(spacing: 20) {
                AskFileIconView(url: URL(fileURLWithPath: "/fixture.png"), thumbnail: true,
                    modified: Date(timeIntervalSince1970: revision)).frame(width: 56, height: 56)
                Text("Scoped Quick Look thumbnail").foregroundStyle(.black)
            }.padding(24).frame(width: 390, height: 120).background(.white)
                .environment(\.askContextImageAccess, access)
                .environment(\.askNativeIconDecoder, { _ in throw MediaFailure.unavailable })
                .environment(\.askQuickLookDecoder, { url, size in
                    XCTAssertEqual(url.path, "/fixture.png"); XCTAssertGreaterThanOrEqual(size.width, 56)
                    await calls.call(); return .init(images: [pixels], numbers: [], pages: 0)
                })
        }
        let view = NSHostingView(rootView: content(1))
        let window = NSWindow(contentRect: .init(x: 80, y: 100, width: 390, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        defer { scope.invalidate(); window.contentView = nil; window.close() }
        func capture() throws -> (NSBitmapImageRep, Int) {
            view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
            var magenta = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) { for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent - c.greenComponent > 0.3, c.blueComponent - c.greenComponent > 0.3 { magenta += 1 }
            } }
            return (rep, magenta)
        }
        for _ in 0..<200 { if try capture().1 > 100 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let snapshot = try capture(); XCTAssertGreaterThan(snapshot.1, 100)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/quicklook-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(snapshot.0.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("quicklook.png"))
        view.rootView = content(2)
        for _ in 0..<100 { if await calls.count == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let count = await calls.count; XCTAssertEqual(count, 2)
        scope.invalidate()
        for _ in 0..<100 { if try capture().1 == 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try capture().1, 0)
        view.rootView = content(3); try await Task.sleep(for: .milliseconds(30))
        let deniedCount = await calls.count; XCTAssertEqual(deniedCount, 2)
    }
}
