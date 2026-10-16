import AppKit
import Darwin
import ImageIO
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private actor ToastPending {
    var continuation: CheckedContinuation<CGImage, Error>?
    var started: Bool { continuation != nil }
    func load() async throws -> CGImage { try await withCheckedThrowingContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: AskAttachmentFixture.image(width: 100, height: 60)); continuation = nil }
}
private final class ToastGate: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run() throws -> ManagedProcess.Result { lock.withLock { calls += 1 }; gate.wait(); throw MediaFailure.unavailable }
}

@MainActor final class RecordingToastIsolationTests: XCTestCase {
    private func folder() throws -> URL { try AskAttachmentFixture.directory() }
    private func source(_ folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("private.mov"); try Data([1, 2, 3]).write(to: url); return url
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Toast work did not settle")
    }
    private func worker() throws -> MediaWorker {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/toast-validation")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }
    func testStrictPosterEnvelopeAndFiniteSourceDimensions() throws {
        var request = MediaRequest(operation: .recordingPosterGIF); request.preview = .init(width: 200, height: 120)
        try request.validate()
        var response = MediaResponse(id: request.id); response.preview = .init(rasters: [.init(width: 160, height: 100)])
        try response.validate(for: request)
        for mutate: (inout MediaRequest) -> Void in [
            { $0.preview = nil }, { $0.preview?.width = 201 }, { $0.preview?.height = 121 },
            { $0.preview?.page = 1 }, { $0.preview?.passage = "x" }, { $0.preview?.start = 0 },
            { $0.preview?.container = .mov }, { $0.preview?.imageType = .gif }, { $0.version = 2 }
        ] { var bad = request; mutate(&bad); XCTAssertThrowsError(try bad.validate()) }
        for mutate: (inout MediaResponse) -> Void in [
            { $0.id = UUID() }, { $0.preview?.rasters = [] }, { $0.preview?.rasters[0].stride = Int.max },
            { $0.preview?.pages = 1 }, { $0.preview?.rasters[0].page = 1 }, { $0.preview?.duration = 1 },
            { $0.preview?.rasters.append(.init(width: 1, height: 1)) }, { $0.items = [.init(text: "x")] }
        ] { var bad = response; mutate(&bad); XCTAssertThrowsError(try bad.validate(for: request)) }
        for pair in [(Double.nan, 1), (1, Double.infinity), (0, 1), (-1, 1), (8193, 1), (1, 8193), (8192, 8192)] {
            XCTAssertThrowsError(try MediaRecordingPosterDecoder.size(pair.0, pair.1))
        }
        try MediaRecordingPosterDecoder.size(4096, 4096)
    }
    func testRealHelperGIFFirstFrameFitTypeAndFrameBounds() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let worker = try worker(), loader = ScreenRecordingTimelineLoader(worker: worker)
        let url = directory.appendingPathComponent("source.gif")
        let original = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 400, height: 100), type: .gif)
        try original.write(to: url)
        let landscape = try await loader.thumbnail(url)
        XCTAssertEqual(landscape.width, 200); XCTAssertEqual(landscape.height, 50)
        XCTAssertEqual(try Data(contentsOf: url), original)
        try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 100, height: 400), type: .gif).write(to: url)
        let portrait = try await loader.thumbnail(url); XCTAssertEqual(portrait.width, 30); XCTAssertEqual(portrait.height, 120)
        try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 10, height: 10), type: .png).write(to: url)
        do { _ = try await loader.thumbnail(url); XCTFail("Renamed PNG accepted as GIF") } catch {}
        let data = NSMutableData(), image = AskAttachmentFixture.image(width: 1, height: 1)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 302, nil))
        for _ in 0..<302 { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); try (data as Data).write(to: url)
        // Separate domain: the earlier intentional failure must not suppress this native validation.
        let second = try self.worker()
        do { _ = try await ScreenRecordingTimelineLoader(worker: second).thumbnail(url); XCTFail("Unbounded GIF frames accepted") } catch {}
        await worker.shutdown(); await second.shutdown()
    }
    func testRealHelperVideoRotationAndDisplayOwnsPixelLease() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silent.mov"); try await ClipboardVideoPlaybackTests.movie(url)
        let worker = try worker(), budget = AskToolPixelBudget(limit: 200 * 120 * 8)
        var image: CGImage? = try await ScreenRecordingTimelineLoader(worker: worker, budget: budget).thumbnail(url)
        XCTAssertEqual(image?.width, 32); XCTAssertEqual(image?.height, 64)
        await worker.shutdown(); XCTAssertThrowsError(try budget.acquire(bytes: 1))
        image = nil; XCTAssertNoThrow(try budget.acquire(bytes: 1))
        let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/toast-validation/silent.mov")
        try? FileManager.default.removeItem(at: evidence); try FileManager.default.copyItem(at: url, to: evidence)
    }
    func testMalformedVideoMissingRasterAndSourceMutationPreserveOriginal() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), native = try worker()
        do { _ = try await ScreenRecordingTimelineLoader(worker: native).thumbnail(url); XCTFail("Malformed movie accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3])); await native.shutdown()
        for mutate in [false, true] {
            let worker = MediaWorker(run: { request, _ in
                let req = try JSONDecoder().decode(MediaRequest.self, from: request.stdin!)
                var response = MediaResponse(id: req.id); response.preview = .init(rasters: [.init(width: 1, height: 1)])
                if mutate {
                    let fd = openat(request.directoryDescriptor, MediaRaster.filename(0), O_CREAT | O_WRONLY, 0o600)
                    let bytes: [UInt8] = [0, 0, 0, 255]; _ = write(fd, bytes, 4); close(fd)
                    try Data([4, 5]).write(to: url)
                }
                return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
            do { _ = try await ScreenRecordingTimelineLoader(worker: worker).thumbnail(url); XCTFail("Missing raster or changed source accepted") } catch {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testSparseByteTypePathAndPixelBoundsBeforeDispatch() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid source dispatched"); throw MediaFailure.unavailable })
        let loader = ScreenRecordingTimelineLoader(worker: worker)
        for (name, bytes) in [("big.mov", MediaRecordingTimeline.inputBytes + 1), ("big.gif", MediaLimits.inputBytes + 1)] {
            let url = directory.appendingPathComponent(name), fd = open(url.path, O_CREAT | O_WRONLY, 0o600)
            XCTAssertEqual(ftruncate(fd, off_t(bytes)), 0); close(fd)
            do { _ = try await loader.thumbnail(url); XCTFail("Byte limit ignored") } catch {}
        }
        let url = try source(directory), link = directory.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        for input in [link, directory, directory.appendingPathComponent("missing.mov"), URL(string: "https://example.invalid/a.mov")!] {
            do { _ = try await loader.thumbnail(input); XCTFail("Invalid source accepted") } catch {}
        }
        do { _ = try await ScreenRecordingTimelineLoader(worker: worker, budget: AskToolPixelBudget(limit: 1)).thumbnail(url); XCTFail("Pixel limit ignored") } catch {}
    }
    func testCancellationRetainsAdmissionsThroughUncooperativeHostCompletion() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), gate = ToastGate(), worker = MediaWorker(run: { _, _ in try gate.run() })
        let loader = ScreenRecordingTimelineLoader(worker: worker)
        let a = Task { try await loader.thumbnail(url) }, b = Task { try await loader.thumbnail(url) }
        try await wait { gate.count == 2 }; a.cancel(); b.cancel()
        do { _ = try await loader.thumbnail(url); XCTFail("Cancelled work freed admission early") } catch {}
        do { _ = try await ScreenRecordingTimelineLoader.inspect(url); XCTFail("Inspection bypassed shared admission") } catch {}
        let cancelled = Task { try await ScreenRecordingTimelineLoader.inspect(url) }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled inspection admitted") }
        catch is CancellationError {} catch { XCTFail("Cancellation must precede admission: \(error)") }
        XCTAssertEqual(worker.activeCount, 2); gate.gate.signal(); gate.gate.signal()
        _ = await a.result; _ = await b.result; await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }
    func testSuppliedPixelsAvoidDecodeAndFailureRetainsExplicitFileActions() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory)
        let supplied = ScreenRecordingToastModel(decode: { _ in XCTFail("Supplied raster decoded again"); throw MediaFailure.unavailable })
        supplied.start(url, thumbnail: AskAttachmentFixture.image(width: 160, height: 100)); await supplied.task?.value
        XCTAssertTrue(supplied.ready); XCTAssertNotNil(supplied.image)
        let failed = ScreenRecordingToastModel(decode: { _ in throw MediaFailure.unavailable })
        failed.start(url, thumbnail: AskAttachmentFixture.image(width: 300, height: 200)); await failed.task?.value
        XCTAssertTrue(failed.ready); XCTAssertNil(failed.image); XCTAssertEqual(failed.fileBytes, 3)
        var count = 0; failed.perform(generation: failed.generation) { _ in count += 1 }
        failed.perform(generation: failed.generation) { _ in count += 1 }; await failed.actionTask?.value
        XCTAssertEqual(count, 1); XCTAssertFalse(failed.busy); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testSourceDeletionMutationAndOldGenerationRejectActions() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), model = ScreenRecordingToastModel()
        for deleted in [false, true] {
            try Data([1, 2, 3]).write(to: url)
            model.start(url, thumbnail: AskAttachmentFixture.image(width: 100, height: 60)); await model.task?.value
            let old = model.generation
            if deleted { try FileManager.default.removeItem(at: url) } else { try Data([9]).write(to: url) }
            model.perform(generation: old) { _ in XCTFail("Changed source action committed") }; await model.actionTask?.value
            XCTAssertNil(model.url); XCTAssertNil(model.image)
            model.perform(generation: old) { _ in XCTFail("Old permission reused") }
        }
        model.start(url, thumbnail: nil); await model.task?.value; XCTAssertNil(model.url)
    }
    func testLateDecoderCannotPublishAfterReplacementOrSourceChange() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), pending = ToastPending(), model = ScreenRecordingToastModel(decode: { _ in try await pending.load() })
        model.start(url, thumbnail: nil); let old = model.task; try await wait { await pending.started }
        model.start(url, thumbnail: AskAttachmentFixture.image(width: 80, height: 40)); await model.task?.value
        await pending.finish(); await old?.value; XCTAssertEqual(model.image?.width, 80)
        model.start(url, thumbnail: nil); try await wait { await pending.started }
        try Data([8, 9, 10, 11]).write(to: url); await pending.finish(); await model.task?.value
        XCTAssertNil(model.url); XCTAssertNil(model.image)
    }
    func testActualPanelAccountOwnerAndOldWindowRetirementFencePrivateState() async throws {
        _ = NSApplication.shared
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), model = ScreenRecordingToastModel(decode: { _ in throw MediaFailure.unavailable })
        var owner: ScreenRecordingToastController? = ScreenRecordingToastController(model: model)
        for action in 0..<6 {
            owner?.showSaved(url, thumbnail: AskAttachmentFixture.image(width: 100, height: 60), duration: 2); await model.task?.value
            XCTAssertTrue(model.ready)
            let panel = try XCTUnwrap(owner?.panel)
            switch action {
            case 0: panel.orderOut(nil)
            case 1: panel.close()
            case 2: panel.miniaturize(nil)
            case 3: NotificationCenter.default.post(name: .authDidLogout, object: nil)
            case 4: NotificationCenter.default.post(name: .authTokenDidRefresh, object: nil)
            default: owner = nil
            }
            XCTAssertNil(model.url); XCTAssertNil(model.image); XCTAssertFalse(model.ready)
        }
        owner = ScreenRecordingToastController(model: model)
        owner?.showRecovery(url, open: {}, discard: {}); await model.task?.value
        let oldPanel = try XCTUnwrap(owner?.panel)
        owner?.showSaved(url, thumbnail: AskAttachmentFixture.image(width: 80, height: 40), duration: 1); await model.task?.value
        oldPanel.orderOut(nil); XCTAssertEqual(model.image?.width, 80)
        owner?.hide()
    }
    func testAccountRetirementFencesUncooperativeDecoderAndPendingAction() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), pending = ToastPending(), model = ScreenRecordingToastModel(decode: { _ in try await pending.load() })
        let owner = ScreenRecordingToastController(model: model)
        owner.showRecovery(url, open: {}, discard: {}); let task = model.task; try await wait { await pending.started }
        NotificationCenter.default.post(name: .authDidLogin, object: nil); await pending.finish(); await task?.value
        XCTAssertNil(model.image); XCTAssertNil(model.url)
        owner.showSaved(url, thumbnail: AskAttachmentFixture.image(width: 100, height: 60), duration: 1); await model.task?.value
        model.perform(generation: model.generation) { _ in XCTFail("Revoked pending action committed") }
        let action = model.actionTask; owner.hide(); await action?.value; XCTAssertNil(model.url)
    }
    func testActualToastPixelsClearOnOrderOut() async throws {
        _ = NSApplication.shared
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try source(directory), owner = ScreenRecordingToastController()
        owner.showSaved(url, thumbnail: AskAttachmentFixture.image(width: 160, height: 100), duration: 3); await owner.model.task?.value
        let panel = try XCTUnwrap(owner.panel), host = try XCTUnwrap(panel.contentView)
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        var blue = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.blueComponent > c.redComponent + 0.2 { blue += 1 }
        } }
        XCTAssertGreaterThan(blue, 1000)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/toast-validation")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("toast.png"))
        panel.orderOut(nil); XCTAssertNil(owner.model.url); XCTAssertNil(owner.model.image); owner.hide()
    }
}
