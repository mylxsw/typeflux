import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import TypefluxMediaProtocol
import TypefluxMediaRuntime
import XCTest
@testable import Typeflux

@MainActor final class AskArtifactImageTests: XCTestCase {
    private func bundle(_ data: Data = Data([1]), mime: String = "image/png") -> AskArtifactBundle {
        let ref = AskArtifactRef(id: UUID().uuidString, ownerId: "owner", conversationId: "conversation", runId: "run",
            version: "1", mediaType: mime, sizeBytes: Int64(data.count), sha256: AskToolPolicy.digest(data), cleanup: "device_persistent")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "image", resources: []), files: ["image": data])
    }
    private func pixels() -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: 20, height: 10)], numbers: [], pages: 0)
    }

    func testMIMEAllowlistAndChildRejectsMislabeledImage() throws {
        let directory = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        for (mime, type) in [(MediaImageType.png, UTType.png), (.jpeg, .jpeg), (.gif, .gif)] {
            try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 20, height: 10), type: type).write(to: input)
            var request = MediaRequest(operation: .previewImage)
            request.preview = .init(width: 100, height: 100, imageType: mime)
            var response = try MediaPreviewDecoder.decode(request, directory: directory)
            XCTAssertEqual(response.preview?.rasters.count, 1)
            XCTAssertEqual(response.preview?.imageType, mime)
            response.preview?.imageType = nil
            XCTAssertThrowsError(try response.validate(for: request))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("raster-0"))
            request.preview?.imageType = mime == .png ? .jpeg : .png
            XCTAssertThrowsError(try MediaPreviewDecoder.decode(request, directory: directory))
            request.operation = .previewPDF
            XCTAssertThrowsError(try request.validate())
        }
        XCTAssertThrowsError(try JSONDecoder().decode(MediaImageType.self, from: Data("\"image/svg+xml\"".utf8)))
    }

    func testClipboardWritesDeclaredOriginalRepresentationWithoutDecoding() {
        let pasteboard = NSPasteboard(name: .init("gul399-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        for type in [MediaImageType.png, .jpeg, .gif] {
            let data = Data([1, 2, 3])
            XCTAssertTrue(AskArtifactImageModel.writeImage(data, mediaType: type.rawValue, pasteboard: pasteboard))
            XCTAssertEqual(pasteboard.data(forType: .init(type.identifier)), data)
        }
        let count = pasteboard.changeCount
        XCTAssertFalse(AskArtifactImageModel.writeImage(Data(), mediaType: "image/svg+xml", pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    func testRealHelperReturnsRawPixelsAndRedactsFailuresWithoutChangingOriginal() async throws {
        let image = AskAttachmentFixture.image(width: 3200, height: 800)
        let bytes = AskAttachmentFixture.encode(image, type: .png)
        let original = bytes
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/artifact-image-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let worker = MediaWorker(run: { process, cancelled in
            var process = process
            process.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        let rendered = try await AskArtifactPresentation.image(bytes, mediaType: "image/png", worker: worker)
        XCTAssertEqual(rendered.images.first?.width, 1600)
        XCTAssertEqual(rendered.images.first?.height, 400)
        XCTAssertEqual(bytes, original)
        for (input, mime, expected) in [(Data(), "image/png", AskArtifactError.tooLarge),
                                      (bytes, "image/svg+xml", .unsupported),
                                      (bytes, "image/jpeg", .corrupt),
                                      (Data("private damaged file".utf8), "image/png", .corrupt),
                                      (Data(repeating: 0, count: AskArtifactStore.maximumFileBytes + 1), "image/png", .tooLarge)] {
            do { _ = try await AskArtifactPresentation.image(input, mediaType: mime, worker: worker); XCTFail("Expected refusal") }
            catch { XCTAssertEqual(error as? AskArtifactError, expected) }
        }
        worker.preventNewWork()
        do { _ = try await AskArtifactPresentation.image(bytes, mediaType: "image/png", worker: worker); XCTFail("Disabled") }
        catch { XCTAssertEqual(error as? AskArtifactError, .unavailable) }
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }

    func testCancellationReachesOwnedWorkerAndCannotPublish() async throws {
        let entered = ArtifactImageGate()
        let worker = MediaWorker(run: { _, cancelled in
            entered.signal()
            while !cancelled() { Thread.sleep(forTimeInterval: 0.001) }
            throw CancellationError()
        })
        let task = Task { try await AskArtifactPresentation.image(Data([1]), mediaType: "image/png", worker: worker) }
        await entered.wait()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testAdmissionRejectsThirdConversionBeforeDispatchAndReleasesAfterCancellation() async throws {
        let first = ArtifactImageGate(), second = ArtifactImageGate()
        func worker(_ gate: ArtifactImageGate) -> MediaWorker {
            MediaWorker(run: { _, cancelled in
                gate.signal()
                while !cancelled() { Thread.sleep(forTimeInterval: 0.001) }
                throw CancellationError()
            })
        }
        let one = worker(first), two = worker(second)
        let a = Task { try await AskArtifactPresentation.image(Data([1]), mediaType: "image/png", worker: one) }
        await first.wait()
        let b = Task { try await AskArtifactPresentation.image(Data([2]), mediaType: "image/png", worker: two) }
        await second.wait()
        let refused = MediaWorker(run: { _, _ in XCTFail("No queued third conversion"); throw CancellationError() })
        do { _ = try await AskArtifactPresentation.image(Data([3]), mediaType: "image/png", worker: refused); XCTFail("Capacity") }
        catch { XCTAssertEqual(error as? AskArtifactError, .unavailable) }
        a.cancel(); b.cancel(); _ = try? await a.value; _ = try? await b.value
        XCTAssertEqual(one.activeCount + two.activeCount, 0)
    }

    func testLoadedImageIsClearedWhenAccessExpiresBeforeCopy() async throws {
        let bundle = bundle(), result = pixels()
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { _, _ in XCTFail("Expired"); return false })
        await model.load(bundle.manifest.ref, access: .init(load: { _ in bundle }, validate: { _ in }))
        XCTAssertNotNil(model.image)
        await model.copy(bundle.manifest.ref, access: .init(load: { _ in bundle }, validate: { _ in throw AskArtifactError.expired }))
        XCTAssertNil(model.image)
    }

    func testPreviewAndCardRenderLoadingReadyAndUnavailableStates() async throws {
        let bundle = bundle(), result = pixels()
        let access = AskArtifactAccess(load: { _ in bundle }, validate: { _ in })
        let gate = ArtifactImageGate(), release = ArtifactImageGate()
        let model = AskArtifactImageModel(decode: { _, _ in gate.signal(); await release.wait(); return result })
        let task = Task { await model.load(bundle.manifest.ref, access: access) }
        await gate.wait()
        let cardModel = AskArtifactImageModel(decode: { _, _ in result })
        let content = VStack {
            AskStoredArtifactCard(ref: bundle.manifest.ref, imageModel: cardModel).environment(\.askArtifactAccess, access)
            AskArtifactPreviewView(bundle: bundle, access: access, close: {}, imageModel: model)
        }
        // Keep the same host alive: destroying it correctly cancels and clears its model.
        let view = NSHostingView(rootView: content
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 880),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        defer { window.close() }
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 880)
        let ready = expectation(description: "Current image displayed")
        let subscription = model.$image.sink { if $0 != nil { ready.fulfill() } }
        defer { subscription.cancel() }
        func render(_ label: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/artifact-image-validation")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(label + ".png"))
        }
        try render("loading")
        release.signal(); await task.value
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(model.image); try render("ready")
        await model.load(bundle.manifest.ref, access: .init())
        XCTAssertNotNil(model.error); try render("unavailable")
    }

    func testLoadAndCopyRevalidateAndPreserveOriginalEncodedBytes() async throws {
        let bundle = bundle(Data([1, 2, 3])); var validations = 0; var loads = 0; var copies = 0
        let result = pixels()
        let access = AskArtifactAccess(load: { _ in loads += 1; return bundle }, validate: { _ in validations += 1 })
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { data, mime in
            XCTAssertEqual(data, bundle.files["image"]); XCTAssertEqual(mime, "image/png"); copies += 1; return true
        })
        await model.load(bundle.manifest.ref, access: access)
        XCTAssertNotNil(model.image); XCTAssertNil(model.error); XCTAssertFalse(model.busy)
        await model.copy(bundle.manifest.ref, access: access)
        XCTAssertEqual(validations, 4); XCTAssertEqual(loads, 2); XCTAssertEqual(copies, 1)
        XCTAssertNotNil(model.image); XCTAssertEqual(bundle.files["image"], Data([1, 2, 3]))
    }

    func testRevocationAfterDecodePreventsDisplayAndClipboardMutation() async throws {
        for copying in [false, true] {
            let bundle = bundle(); let gate = ArtifactImageGate(); let release = ArtifactImageGate()
            var allowed = true; var copies = 0; let result = pixels()
            let access = AskArtifactAccess(load: { _ in bundle }, validate: { _ in if !allowed { throw AskArtifactError.denied } })
            let model = AskArtifactImageModel(decode: { _, _ in gate.signal(); await release.wait(); return result },
                                               write: { _, _ in copies += 1; return true })
            let task = Task { if copying { await model.copy(bundle.manifest.ref, access: access) }
                             else { await model.load(bundle.manifest.ref, access: access) } }
            await gate.wait(); allowed = false; release.signal(); await task.value
            XCTAssertEqual(copies, 0); XCTAssertNil(model.image)
            XCTAssertEqual(model.error, AskArtifactError.denied.localizedDescription)
            XCTAssertFalse(model.busy)
        }
    }

    func testOldSelectionAndUncooperativeDecoderCannotOverwriteNewSnapshot() async throws {
        let old = bundle(Data([1])), new = bundle(Data([2]))
        let gate = ArtifactImageGate(), release = ArtifactImageGate(); let result = pixels()
        let model = AskArtifactImageModel(decode: { data, _ in
            if data == Data([1]) { gate.signal(); await release.wait() }
            return result
        })
        let first = Task { await model.load(old.manifest.ref, access: .init(load: { _ in old }, validate: { _ in })) }
        await gate.wait()
        await model.load(new.manifest.ref, access: .init(load: { _ in new }, validate: { _ in }))
        let snapshot = model.image
        release.signal(); await first.value
        XCTAssertTrue(model.image === snapshot); XCTAssertFalse(model.busy)
        model.cancel(); XCTAssertNil(model.image); XCTAssertNil(model.error)
    }

    func testCancellationAndDuplicateCopyDoNotMutatePasteboard() async throws {
        let bundle = bundle(); let gate = ArtifactImageGate(), release = ArtifactImageGate(); let result = pixels()
        var copies = 0; var loads = 0
        let model = AskArtifactImageModel(decode: { _, _ in gate.signal(); await release.wait(); return result },
                                          write: { _, _ in copies += 1; return true })
        let access = AskArtifactAccess(load: { _ in loads += 1; return bundle }, validate: { _ in })
        let task = Task { await model.copy(bundle.manifest.ref, access: access) }
        await gate.wait()
        await model.copy(bundle.manifest.ref, access: access)
        XCTAssertEqual(loads, 1)
        task.cancel(); model.cancel(); release.signal(); await task.value
        XCTAssertEqual(copies, 0); XCTAssertNil(model.image); XCTAssertNil(model.error)
    }

    func testFailuresKeepSavedArtifactAndExposeOnlySafeErrors() async throws {
        let bundle = bundle(); let access = AskArtifactAccess(load: { _ in bundle }, validate: { _ in })
        let result = pixels()
        let unavailable = AskArtifactImageModel(decode: { _, _ in throw NSError(domain: "secret/path", code: 1) })
        await unavailable.load(bundle.manifest.ref, access: access)
        XCTAssertEqual(unavailable.error, AskArtifactError.unavailable.localizedDescription)
        let refused = AskArtifactImageModel(decode: { _, _ in result }, write: { _, _ in false })
        await refused.copy(bundle.manifest.ref, access: access)
        XCTAssertEqual(refused.error, AskArtifactError.unavailable.localizedDescription)
        let empty = AskArtifactImageModel(decode: { _, _ in .init(images: [], numbers: [], pages: 0) })
        await empty.load(bundle.manifest.ref, access: access)
        XCTAssertEqual(empty.error, AskArtifactError.corrupt.localizedDescription)
        var damaged = bundle; damaged.files["image"] = Data([9])
        let noDecode = AskArtifactImageModel(decode: { _, _ in XCTFail("Must reject before decoder"); return result })
        await noDecode.load(bundle.manifest.ref, access: .init(load: { _ in damaged }, validate: { _ in }))
        XCTAssertEqual(noDecode.error, AskArtifactError.corrupt.localizedDescription)
        await noDecode.load(bundle.manifest.ref, access: .init(load: { _ in bundle }, validate: { _ in throw AskArtifactError.expired }))
        XCTAssertEqual(noDecode.error, AskArtifactError.expired.localizedDescription)
        XCTAssertEqual(bundle.files["image"], Data([1]))
    }
}

/// Continuations avoid timing-dependent sleeps while a fake decoder ignores cancellation.
private final class ArtifactImageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if open { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func signal() {
        lock.lock(); open = true; let pending = waiters; waiters = []; lock.unlock()
        pending.forEach { $0.resume() }
    }
}
