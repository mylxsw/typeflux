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

@MainActor final class ClipboardThumbnailIsolationTests: XCTestCase {
    private func result() -> AskFilePreviewPDF.Result {
        let context = CGContext(data: nil, width: 56, height: 40, bitsPerComponent: 8, bytesPerRow: 224,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 56, height: 40))
        return .init(images: [context.makeImage()!], numbers: [], pages: 0)
    }
    private func fixture() throws -> URL { try AskAttachmentFixture.directory() }
    private func worker() throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-thumbnail-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 3, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
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

    func testPausePreservesHistoryButHiddenPreviewAndOwnerReleaseClearPixels() async throws {
        let panel = ClipboardPanelModel(), entry = ClipboardTestSupport.entry(.image, imagePath: "/private/missing.png"), raster = result()
        panel.reset(entries: [entry]); panel.showsPreview = true
        var controller: ClipboardPanelController? = ClipboardPanelController(settingsStore: settings(), thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
        controller?.present(panel)
        let access = controller!.thumbnails.access(for: entry), image = AskContextImageModel(decode: { _ in raster })
        await image.load("image", access: access)
        panel.isRecordingPaused = true; XCTAssertTrue(access.allows()); XCTAssertNotNil(image.image)
        panel.showsPreview = false; XCTAssertFalse(access.allows()); XCTAssertNil(image.image)
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
