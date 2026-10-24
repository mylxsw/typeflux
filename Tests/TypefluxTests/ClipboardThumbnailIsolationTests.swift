import AppKit
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

private final class ClipboardThumbnailBlock: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run() throws -> ManagedProcess.Result { lock.withLock { calls += 1 }; gate.wait(); throw MediaFailure.unavailable }
}

private final class ClipboardThumbnailWorkerCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

private actor ClipboardThumbnailCalls {
    var count = 0
    func add() { count += 1 }
}
private actor ClipboardThumbnailPending {
    var pending: CheckedContinuation<AskFilePreviewPDF.Result, Error>?
    func read() async throws -> AskFilePreviewPDF.Result { try await withCheckedThrowingContinuation { pending = $0 } }
    var started: Bool { pending != nil }
    func resolve(_ value: AskFilePreviewPDF.Result) { pending?.resume(returning: value); pending = nil }
}
private actor ClipboardThumbnailDecodeProbe {
    private let fallback: AskFilePreviewPDF.Result
    private var startedKeys: [String] = []
    private var continuations: [String: CheckedContinuation<AskFilePreviewPDF.Result, Never>] = [:]
    init(fallback: AskFilePreviewPDF.Result) { self.fallback = fallback }
    var started: [String] { startedKeys }
    func decode(_ key: String) async -> AskFilePreviewPDF.Result {
        await withCheckedContinuation { continuation in
            startedKeys.append(key)
            continuations[key] = continuation
            Task {
                try? await Task.sleep(for: .seconds(2))
                finish(key, with: fallback)
            }
        }
    }
    func finish(_ key: String, with result: AskFilePreviewPDF.Result) {
        continuations.removeValue(forKey: key)?.resume(returning: result)
    }
}

@MainActor final class ClipboardThumbnailIsolationTests: XCTestCase {
    private func result() -> AskFilePreviewPDF.Result {
        let context = CGContext(data: nil, width: 56, height: 40, bitsPerComponent: 8, bytesPerRow: 224,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 56, height: 40))
        return .init(images: [context.makeImage()!], numbers: [], pages: 0)
    }
    private func fixture() throws -> URL { try AskAttachmentFixture.directory() }
    private func worker(calls: ClipboardThumbnailWorkerCalls? = nil) throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-thumbnail-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 3, run: { request, cancelled in
            calls?.add()
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }

    func testDiskThumbnailsReuseAcrossOpeningsWhileLargePreviewLoadsOriginal() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ClipboardThumbnailDiskCache(directory: folder.appendingPathComponent("cache"))
        let calls = ClipboardThumbnailWorkerCalls(), worker = try worker(calls: calls)
        var files: [URL] = []
        for index in 0..<6 {
            let url = folder.appendingPathComponent("image-\(index).png")
            try ClipboardTestSupport.imageData(width: 2000, height: 1000).write(to: url)
            files.append(url)
        }
        let coldStart = ContinuousClock.now
        for url in files {
            let result = try await ClipboardThumbnailProvider.decode(url, edge: 240, worker: worker, diskCache: cache)
            XCTAssertEqual(result.images.first?.width, 240)
        }
        let cold = coldStart.duration(to: .now)
        XCTAssertEqual(calls.count, 6)
        let hotStart = ContinuousClock.now
        for url in files {
            let result = try await ClipboardThumbnailProvider.decode(url, edge: 240, worker: worker, diskCache: cache)
            XCTAssertEqual(result.images.first?.height, 120)
        }
        let hot = hotStart.duration(to: .now)
        XCTAssertEqual(calls.count, 6, "Reopening must not launch decoders or read original image bytes")
        print("Clipboard thumbnail comparison (6 images): first generation=\(cold), disk reuse=\(hot), worker launches on reuse=0")
        let preview = try await ClipboardThumbnailProvider.decode(files[0], edge: 900, worker: worker, diskCache: cache)
        XCTAssertEqual(preview.images.first?.width, 900)
        XCTAssertEqual(calls.count, 7)
        await worker.shutdown()
        do {
            _ = try await ClipboardThumbnailProvider.decode(files[0], edge: 240, worker: worker, diskCache: cache)
            XCTFail("Cached pixels must not bypass disabled worker authorization")
        } catch {}
        XCTAssertEqual(calls.count, 7)
    }

    func testBackgroundPreparationBoundsRecentEntriesAndUsesOnlyListSize() async throws {
        let calls = ClipboardThumbnailCalls(), raster = result()
        let entries = (0..<20).map { index in
            ClipboardTestSupport.entry(.images, filePaths: (0..<10).map { "/private/\(index)-\($0).png" })
        }
        let task = ClipboardThumbnailProvider.prepare(entries, using: { _, edge in
            XCTAssertEqual(edge, 240)
            await calls.add()
            return raster
        })
        XCTAssertNotNil(task)
        await task?.value
        let count = await calls.count
        XCTAssertEqual(count, 36, "Only the first 12 entries and at most three images per entry are warmed")
        XCTAssertNil(ClipboardThumbnailProvider.prepare([]))
        XCTAssertNil(ClipboardThumbnailProvider.prepare([ClipboardTestSupport.entry(.text, text: "text")]))
    }
    private func settings() -> SettingsStore {
        let suite = "ClipboardThumbnailIsolationTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    func testRealImageHelperRereadsChangedBytesAndRefusesMalformedInput() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png"), worker = try worker()
        try ClipboardTestSupport.imageData(width: 120, height: 60).write(to: file)
        let first = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker)
        XCTAssertEqual(first.images.first?.width, 64); XCTAssertEqual(first.images.first?.height, 32)
        try ClipboardTestSupport.imageData(width: 40, height: 100).write(to: file)
        let next = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker)
        XCTAssertEqual(next.images.first?.height, 64); XCTAssertLessThan(next.images.first?.width ?? 999, 64)
        let malformed = Data("invalid image".utf8); try malformed.write(to: file)
        do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: file), malformed); await worker.shutdown()
    }

    func testRealQuickLookHandlesPrivatePDFAndRetainsOriginal() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = ClipboardTestSupport.makePDF(named: "document.pdf", in: folder, pages: 1), worker = try worker()
        let original = try Data(contentsOf: file)
        let pixels = try await ClipboardThumbnailProvider.decode(file, edge: 120, worker: worker)
        XCTAssertEqual(pixels.images.count, 1); XCTAssertLessThanOrEqual(pixels.images[0].height, 120)
        XCTAssertEqual(try Data(contentsOf: file), original); await worker.shutdown()
    }

    func testInvalidSizePathAndPrecancelledCallsNeverDispatch() async throws {
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid request dispatched"); throw MediaFailure.unavailable })
        for edge in [CGFloat(0), -1, .nan, .infinity, 901, .greatestFiniteMagnitude] {
            do { _ = try await ClipboardThumbnailProvider.decode(URL(fileURLWithPath: "/x.png"), edge: edge, worker: worker); XCTFail() } catch {}
        }
        for url in [URL(string: "https://example.test/image.png")!, URL(fileURLWithPath: "/" + String(repeating: "x", count: 4096))] {
            do { _ = try await ClipboardThumbnailProvider.decode(url, edge: 64, worker: worker); XCTFail() } catch {}
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClipboardThumbnailProvider.decode(URL(fileURLWithPath: "/x.png"), edge: 64, worker: worker)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEncodedInputBudgetRefusesOversizedFileBeforeLaunching() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("huge.png")
        let fd = open(file.path, O_CREAT | O_RDWR, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 51 * 1024 * 1024), 0); close(fd)
        let worker = MediaWorker(run: { _, _ in XCTFail("Oversized input dispatched"); throw MediaFailure.unavailable })
        do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker); XCTFail() } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellationRetainsAdmissionThroughUncooperativeReturn() async throws {
        let block = ClipboardThumbnailBlock(), worker = MediaWorker(run: { _, _ in try block.run() })
        let url = URL(fileURLWithPath: "/private/fixture.pdf")
        let first = Task { try await ClipboardThumbnailProvider.decode(url, edge: 64, worker: worker) }
        let second = Task { try await ClipboardThumbnailProvider.decode(url, edge: 64, worker: worker) }
        for _ in 0..<200 where block.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(block.count, 2); first.cancel(); second.cancel()
        do { _ = try await ClipboardThumbnailProvider.decode(url, edge: 64, worker: worker); XCTFail() } catch {}
        XCTAssertEqual(block.count, 2); block.gate.signal(); block.gate.signal()
        _ = try? await first.value; _ = try? await second.value
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testChildCrashAndHangFailWithoutDeletingOriginalOrReplaying() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png"), data = ClipboardTestSupport.imageData()
        try data.write(to: file)
        for body in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let executable = folder.appendingPathComponent(UUID().uuidString)
            try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let worker = MediaWorker(executable: executable, timeout: 0.1), start = ContinuousClock.now
            do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker); XCTFail() } catch {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(2)); await worker.shutdown()
            XCTAssertEqual(worker.activeCount, 0); XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testSessionRejectsChangedEntryWithSameIDAndOldWindowEpoch() async throws {
        let session = ClipboardThumbnailSession(), panel = ClipboardPanelModel(), id = UUID()
        let entry = ClipboardTestSupport.entry(.image, id: id, imagePath: "/private/a.png")
        panel.reset(entries: [entry]); XCTAssertFalse(session.access(for: entry).allows())
        session.begin(panel); let access = session.access(for: entry); XCTAssertTrue(access.allows())
        let raster = result(), image = AskContextImageModel(decode: { _ in raster })
        await image.load("image", access: access); XCTAssertNotNil(image.image)
        panel.replaceEntries([ClipboardTestSupport.entry(.image, id: id, imagePath: "/private/b.png")])
        XCTAssertFalse(access.allows()); XCTAssertNil(image.displayed("image", access: access))
        session.changed(); XCTAssertNil(image.image)
        panel.reset(entries: [entry]); session.begin(panel)
        XCTAssertFalse(access.allows()); XCTAssertTrue(session.access(for: entry).allows())
        session.end(); XCTAssertFalse(session.access(for: entry).allows())
    }

    func testDeletedEntryAndSessionClosureRejectLatePixels() async throws {
        let session = ClipboardThumbnailSession(), panel = ClipboardPanelModel(), raster = result()
        let entry = ClipboardTestSupport.entry(.image, imagePath: "/private/a.png")
        panel.reset(entries: [entry]); session.begin(panel)
        let pending = ClipboardThumbnailPending()
        let image = AskContextImageModel(decode: { _ in try await pending.read() })
        let access = session.access(for: entry), task = Task { await image.load("image", access: access) }
        for _ in 0..<100 { if await pending.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        panel.replaceEntries([]); session.changed(); await pending.resolve(raster); await task.value
        XCTAssertNil(image.image)
        session.end(); XCTAssertFalse(access.allows())
    }

    func testScopeCapacityIsBoundedBeforeDecoding() async throws {
        let session = ClipboardThumbnailSession(), panel = ClipboardPanelModel(), raster = result()
        let entry = ClipboardTestSupport.entry(.image, imagePath: "/private/a.png")
        panel.reset(entries: [entry]); session.begin(panel)
        let calls = ClipboardThumbnailCalls()
        let images = (0..<17).map { _ in AskContextImageModel(maximumEdge: 56, decode: { _ in await calls.add(); return raster }) }
        for image in images { await image.load("image", access: session.access(for: entry)) }
        let count = await calls.count; XCTAssertEqual(count, 16); XCTAssertNil(images.last?.image)
        session.end(); XCTAssertTrue(images.allSatisfy { $0.image == nil })
    }

    func testThumbnailCacheReusesPixelsUntilThePresentationEnds() async throws {
        let cache = ClipboardThumbnailCache(), calls = ClipboardThumbnailCalls(), raster = result()
        let url = URL(fileURLWithPath: "/private/reused.png"), firstEpoch = cache.clear()
        let decode: ClipboardThumbnailDecoding = { _, _ in await calls.add(); return raster }
        _ = try await cache.decode(url, edge: 240, epoch: firstEpoch, using: decode)
        _ = try await cache.decode(url, edge: 240, epoch: firstEpoch, using: decode)
        let firstCount = await calls.count
        XCTAssertEqual(firstCount, 1)

        let secondEpoch = cache.clear()
        do {
            _ = try await cache.decode(url, edge: 240, epoch: firstEpoch, using: decode)
            XCTFail("A previous panel session must not receive cached pixels")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        _ = try await cache.decode(url, edge: 240, epoch: secondEpoch, using: decode)
        let secondCount = await calls.count
        XCTAssertEqual(secondCount, 2)
    }

    func testVisibleThumbnailRequestsQueueAndSelectedPreviewGetsNextSlot() async throws {
        let cache = ClipboardThumbnailCache(), raster = result()
        let probe = ClipboardThumbnailDecodeProbe(fallback: raster)
        let epoch = cache.clear()
        func request(_ name: String, edge: CGFloat = 240) -> Task<AskFilePreviewPDF.Result, Error> {
            Task {
                try await cache.decode(URL(fileURLWithPath: "/private/\(name).png"), edge: edge, epoch: epoch,
                    using: { url, _ in await probe.decode(url.deletingPathExtension().lastPathComponent) })
            }
        }
        let first = request("first"), second = request("second")
        for _ in 0..<100 {
            if await probe.started.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initial = await probe.started
        XCTAssertEqual(initial.count, 2)
        guard initial.count == 2 else { return }
        let queued = request("queued")
        try await Task.sleep(for: .milliseconds(20))
        let selected = request("selected", edge: 900)
        try await Task.sleep(for: .milliseconds(30))
        let beforeRelease = await probe.started
        XCTAssertEqual(beforeRelease.count, 2)

        await probe.finish(initial[0], with: raster)
        for _ in 0..<100 {
            if await probe.started.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let afterFirst = await probe.started
        XCTAssertEqual(afterFirst.last, "selected")
        await probe.finish(initial[1], with: raster)
        for _ in 0..<100 {
            if await probe.started.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let afterSecond = await probe.started
        XCTAssertEqual(afterSecond.last, "queued")
        await probe.finish("selected", with: raster)
        await probe.finish("queued", with: raster)
        _ = try await (first.value, second.value, selected.value, queued.value)
    }

    func testSelectionAndDateRefreshKeepLoadedThumbnailAuthorized() {
        let session = ClipboardThumbnailSession(), panel = ClipboardPanelModel(), id = UUID()
        let original = ClipboardTestSupport.entry(.image, id: id, date: Date(timeIntervalSince1970: 100), imagePath: "/private/a.png")
        let other = ClipboardTestSupport.entry(.text, text: "other")
        panel.reset(entries: [original, other])
        session.begin(panel)
        let access = session.access(for: original), epoch = access.epoch
        panel.select(index: 1)
        XCTAssertTrue(access.allows())
        XCTAssertEqual(session.access(for: original).epoch, epoch)
        let updated = ClipboardTestSupport.entry(.image, id: id, date: Date(timeIntervalSince1970: 200), imagePath: "/private/a.png")
        panel.replaceEntries([updated, other])
        session.changed()
        XCTAssertTrue(access.allows())
        XCTAssertEqual(session.access(for: updated).epoch, epoch)
        panel.replaceEntries([ClipboardTestSupport.entry(.text, text: "new"), updated, other])
        session.changed()
        XCTAssertTrue(access.allows())
        XCTAssertEqual(session.access(for: updated).epoch, epoch)
        session.end()
        XCTAssertFalse(access.allows())
    }

    func testTransientThumbnailWorkerRefusalRetriesOnce() async throws {
        let cache = ClipboardThumbnailCache(), calls = ClipboardThumbnailCalls(), raster = result()
        let epoch = cache.clear()
        let image = try await cache.decode(URL(fileURLWithPath: "/private/retry.png"), edge: 240, epoch: epoch,
            using: { _, _ in
                await calls.add()
                if await calls.count == 1 { throw MediaFailure.unavailable }
                return raster
            })
        XCTAssertEqual(image.images.count, 1)
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testChangingSelectionKeepsVisibleRowPixels() async throws {
        let panel = ClipboardPanelModel(), entry = ClipboardTestSupport.entry(.image, imagePath: "/private/a.png")
        panel.reset(entries: [entry, ClipboardTestSupport.entry(.text, text: "next")])
        let controller = ClipboardPanelController(settingsStore: settings(), thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
        controller.present(panel); defer { controller.dismiss() }
        let raster = result()
        let access = controller.thumbnails.access(for: entry), image = AskContextImageModel(decode: { _ in raster })
        await image.load("image", access: access)
        panel.select(index: 1)
        XCTAssertTrue(access.allows()); XCTAssertNotNil(image.displayed("image", access: access))
    }

    func testActualOrderOutCloseAndAccountChangeRevokePanelScope() async throws {
        let panel = ClipboardPanelModel(), entry = ClipboardTestSupport.entry(.image, imagePath: "/private/missing.png")
        panel.reset(entries: [entry]); let controller = ClipboardPanelController(settingsStore: settings(), thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
        defer { controller.dismiss() }
        controller.present(panel); let first = controller.thumbnails.access(for: entry)
        XCTAssertTrue(first.allows()); controller.presentedWindow?.orderOut(nil); XCTAssertFalse(first.allows())
        controller.present(panel); let second = controller.thumbnails.access(for: entry)
        controller.presentedWindow?.close(); XCTAssertFalse(second.allows())
        controller.present(panel); let third = controller.thumbnails.access(for: entry)
        NotificationCenter.default.post(name: .authDidLogout, object: nil)
        XCTAssertFalse(third.allows()); XCTAssertFalse(controller.isPresented)
        controller.present(panel); let beforeDelete = controller.thumbnails.access(for: entry)
        panel.replaceEntries([]); XCTAssertFalse(beforeDelete.allows())
    }

    func testPauseAndPreviewToggleKeepRowsButOwnerReleaseClearsPixels() async throws {
        let panel = ClipboardPanelModel(), entry = ClipboardTestSupport.entry(.image, imagePath: "/private/missing.png"), raster = result()
        panel.reset(entries: [entry]); panel.showsPreview = true
        var controller: ClipboardPanelController? = ClipboardPanelController(settingsStore: settings(), thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
        controller?.present(panel)
        let access = controller!.thumbnails.access(for: entry), image = AskContextImageModel(decode: { _ in raster })
        await image.load("image", access: access)
        panel.isRecordingPaused = true; XCTAssertTrue(access.allows()); XCTAssertNotNil(image.image)
        panel.showsPreview = false; XCTAssertTrue(access.allows()); XCTAssertNotNil(image.image)
        let next = controller!.thumbnails.access(for: entry); await image.load("image", access: next)
        let window = controller?.presentedWindow
        controller = nil
        for _ in 0..<100 where image.image != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(image.image); XCTAssertFalse(next.allows()); window?.orderOut(nil)
    }

    func testActualThumbnailViewRendersThenClearsOnDeletion() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("synthetic.png"); try ClipboardTestSupport.imageData().write(to: file)
        let entry = ClipboardTestSupport.entry(.image, imagePath: file.path, imagePixelSize: .init(width: 56, height: 40))
        let model = ClipboardPanelModel(); model.reset(entries: [entry]); model.showsPreview = true
        let raster = result(), store = settings(); store.appearanceMode = .light
        let controller = ClipboardPanelController(settingsStore: store, thumbnailDecoder: { _, _ in raster })
        controller.present(model); defer { controller.dismiss() }
        let window = try XCTUnwrap(controller.presentedWindow), view = try XCTUnwrap(window.contentView)
        func capture() throws -> (NSBitmapImageRep, Int) {
            view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
            var count = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent - c.greenComponent > 0.3, c.blueComponent - c.greenComponent > 0.3 { count += 1 }
            } }
            return (rep, count)
        }
        for _ in 0..<200 { if try capture().1 > 100 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let snapshot = try capture(); XCTAssertGreaterThan(snapshot.1, 100)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-thumbnail-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(snapshot.0.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("clipboard-thumbnails.png"))
        model.replaceEntries([])
        for _ in 0..<100 { if try capture().1 == 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try capture().1, 0); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
