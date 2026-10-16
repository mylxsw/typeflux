import AppKit
import SwiftUI
import TypefluxMediaProtocol
import XCTest
@testable import Typeflux

private actor ContextImageGate {
    var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { count += 1; await withCheckedContinuation { waiters.append($0) } }
    func release() { let old = waiters; waiters = []; old.forEach { $0.resume() } }
}
private final class ContextWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func signal() { lock.withLock { entered = true } }
    var ready: Bool { lock.withLock { entered } }
}

@MainActor final class AskContextImageTests: XCTestCase {
    private func pixels(_ width: Int = 20) -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: width, height: 12)], numbers: [], pages: 0)
    }
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func entered(_ gate: ContextImageGate, _ count: Int = 1) async throws {
        for _ in 0..<200 { if await gate.count >= count { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Decoder did not enter")
    }
    private func source(_ data: Data, mime: String = "image/png") -> String { "data:\(mime);base64," + data.base64EncodedString() }

    func testInputBoundsAndMIMEAreCheckedWithoutNativeParsing() throws {
        for mime in ["image/png", "image/jpeg", "image/gif"] {
            let (data, type) = try AskContextImageDecoder.input(source(Data([1]), mime: mime))
            XCTAssertEqual(data, Data([1])); XCTAssertEqual(type.rawValue, mime)
        }
        for value in ["", "https://private.test/image", "data:image/png,abc", "data:image/png;base64,", "data:image/png;base64,?",
                      "data:image/svg+xml;base64,AQ==", "data:image/png;charset=utf8;base64,AQ==",
                      String(repeating: "a", count: AskContextImageDecoder.maximumEncodedBytes + 1)] {
            XCTAssertThrowsError(try AskContextImageDecoder.input(value))
        }
    }

    func testRealHelperValidatesMIMEAndMalformedBytesWithoutChangingSource() async throws {
        let data = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 80, height: 40), type: .png)
        let original = source(data)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/context-image-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worker = MediaWorker(run: { process, cancelled in
            var process = process
            process.environment["LLVM_PROFILE_FILE"] = directory.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        let result = try await AskContextImageDecoder.decode(original, worker: worker)
        XCTAssertEqual(result.images.first?.width, 80); XCTAssertEqual(result.images.first?.height, 40)
        XCTAssertEqual(original, source(data))
        for invalid in [source(data, mime: "image/jpeg"), source(Data(data.prefix(20))), source(Data([1, 2, 3]))] {
            do { _ = try await AskContextImageDecoder.decode(invalid, worker: worker); XCTFail("Invalid original accepted") } catch {}
        }
        await worker.shutdown()
    }

    func testDecoderAdmissionAndCancellationReachOwnedWorkers() async throws {
        let one = ContextWorkerGate(), two = ContextWorkerGate()
        func worker(_ gate: ContextWorkerGate) -> MediaWorker {
            MediaWorker(run: { _, cancelled in
                gate.signal()
                while !cancelled() { Thread.sleep(forTimeInterval: 0.001) }
                throw CancellationError()
            })
        }
        let aWorker = worker(one), bWorker = worker(two), value = source(Data([1]))
        let a = Task { try await AskContextImageDecoder.decode(value, worker: aWorker) }
        let b = Task { try await AskContextImageDecoder.decode(value, worker: bWorker) }
        for _ in 0..<200 where !one.ready || !two.ready { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(one.ready && two.ready)
        do { _ = try await AskContextImageDecoder.decode(value, worker: MediaWorker(timeout: 3)); XCTFail("Third task admitted") }
        catch { XCTAssertEqual(error as? MediaFailure, .unavailable) }
        a.cancel(); b.cancel(); _ = try? await a.value; _ = try? await b.value
        XCTAssertEqual(aWorker.activeCount + bWorker.activeCount, 0)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await AskContextImageDecoder.decode(value, worker: MediaWorker(timeout: 3)) }
        do { _ = try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExactContentDeduplicatesAndNeverTrustsReusedIdentityOrLength() async throws {
        let scope = AskImagePresentationScope(), result = pixels(), gate = ContextImageGate()
        let model = AskContextImageModel(decode: { _ in await gate.wait(); return result })
        let first = Task { await model.load("first", access: access(scope)) }
        try await entered(gate); await gate.release(); await first.value
        let image = try XCTUnwrap(model.image)
        await model.load("first", access: access(scope)); XCTAssertTrue(model.image === image)
        XCTAssertNil(model.displayed("other", access: access(scope)))
        let second = Task { await model.load("other", access: access(scope)) }
        try await entered(gate, 2); await gate.release(); await second.value
        XCTAssertFalse(model.image === image)
        await model.load(nil, access: access(scope)); XCTAssertNil(model.image)
    }

    func testPixelLeasePrecedesWorkAndSurvivesUncooperativeCancellation() async throws {
        let gate = ContextImageGate(), scope = AskImagePresentationScope(), result = pixels()
        let budget = AskToolPixelBudget(limit: 1600 * 1600 * 4)
        let first = AskContextImageModel(budget: budget, decode: { _ in await gate.wait(); return result })
        let task = Task { await first.load("old", access: access(scope)) }
        try await entered(gate); first.cancel()
        let second = AskContextImageModel(budget: budget, decode: { _ in result })
        await second.load("new", access: access(scope)); XCTAssertTrue(second.unavailable)
        await gate.release(); await task.value; XCTAssertNil(first.image)
        second.cancel() // Reopening is deliberate; body recomputation does not retry a failed projection.
        await second.load("new", access: access(scope)); XCTAssertNotNil(second.image)
        scope.invalidate(); XCTAssertNil(second.image)
    }

    func testOldResultAndOldDeniedAccessCannotOverwriteNewSelection() async throws {
        let gate = ContextImageGate(), scope = AskImagePresentationScope(), result = pixels()
        let model = AskContextImageModel(decode: { value in if value == "old" { await gate.wait() }; return result })
        let oldAccess = access(scope)
        let old = Task { await model.load("old", access: oldAccess) }
        try await entered(gate); scope.invalidate()
        await model.load("new", access: access(scope)); let image = try XCTUnwrap(model.image)
        await model.load("old", access: oldAccess); XCTAssertTrue(model.image === image)
        await gate.release(); await old.value; XCTAssertTrue(model.image === image)
        scope.invalidate(); XCTAssertNil(model.image)
    }

    func testAuthorizationIsRecheckedAfterAwaitAndOnEveryProjection() async throws {
        let gate = ContextImageGate(), scope = AskImagePresentationScope(), result = pixels()
        var authorized = true
        let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { authorized })
        let model = AskContextImageModel(decode: { _ in await gate.wait(); return result })
        let first = Task { await model.load("private", access: original) }
        try await entered(gate); authorized = false; await gate.release(); await first.value
        XCTAssertNil(model.image); XCTAssertFalse(model.unavailable)
        authorized = true
        let second = Task { await model.load("private", access: original) }
        try await entered(gate, 2); await gate.release(); await second.value
        authorized = false
        XCTAssertNil(model.displayed("private", access: access(scope)), "Fresh access must not bless old account pixels")
        await model.load("private", access: original); XCTAssertNil(model.image)
    }

    func testFailureDoesNotRetryFromGettersAndInvalidRastersFailClosed() async throws {
        let scope = AskImagePresentationScope()
        for result in [AskFilePreviewPDF.Result(images: [], numbers: [], pages: 0), pixels(1601),
                       AskFilePreviewPDF.Result(images: pixels().images + pixels().images, numbers: [], pages: 0)] {
            let model = AskContextImageModel(decode: { _ in result })
            await model.load("invalid", access: access(scope)); XCTAssertTrue(model.unavailable); XCTAssertNil(model.image)
            await model.load("invalid", access: access(scope)); XCTAssertTrue(model.unavailable)
            model.cancel()
        }
        let model = AskContextImageModel(decode: { _ in throw MediaFailure.unreadable })
        await model.load("bad", access: access(scope)); XCTAssertTrue(model.unavailable)
        scope.invalidate(); XCTAssertFalse(model.unavailable)
        await model.load("bad", access: .init()); XCTAssertNil(model.image)
        await model.load(String(repeating: "a", count: AskContextImageDecoder.maximumEncodedBytes + 1), access: access(scope))
        XCTAssertTrue(model.unavailable)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load("bad", access: access(scope)) }
        await cancelled.value; XCTAssertTrue(model.unavailable)
        model.cancel()
    }

    func testProductionAccessFencesLocalAccountSelectionVisibilityAndLoginChanges() async throws {
        for fixture in [try AskTestFixture(localOnly: true), try AskTestFixture(authenticated: false), try AskTestFixture()] {
            defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
            fixture.model.owner = fixture.model.session()?.owner ?? ""
            let launcher = fixture.model.contextImageAccess(launcher: true)
            XCTAssertTrue(launcher.allows())
            fixture.model.launcherPresentationID = UUID(); XCTAssertFalse(launcher.allows())
            let conversation = fixture.model.contextImageAccess(launcher: false)
            XCTAssertTrue(conversation.allows())
            fixture.model.selectionGeneration = UUID(); XCTAssertFalse(conversation.allows())
            fixture.model.setLauncherImagesVisible(false); XCTAssertFalse(fixture.model.contextImageAccess(launcher: true).allows())
            fixture.model.setLauncherImagesVisible(true); XCTAssertTrue(fixture.model.contextImageAccess(launcher: true).allows())
            let result = pixels(), image = AskContextImageModel(decode: { _ in result })
            await image.load("private", access: fixture.model.contextImageAccess(launcher: true)); XCTAssertNotNil(image.image)
            NotificationCenter.default.post(name: .authTokenDidRefresh, object: nil)
            for _ in 0..<100 where image.image != nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNil(image.image)
            let stale = fixture.model.contextImageAccess(launcher: true)
            fixture.sessionState.owner = "other"
            if fixture.model.session()?.owner == "other" { XCTAssertFalse(stale.allows()); XCTAssertFalse(fixture.model.contextImageAccess(launcher: true).allows()) }
        }
    }

    func testAttachmentRecoveryAndProvenanceKeepOriginalsWhenPreviewFails() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
        let original = "data:image/png;base64,?"
        let attachment = AskAttachment(id: "same-id", kind: .image, name: "Original image", image: original)
        let message = AskMessage(id: "screenshot", role: "user", text: "Saved question", image: original, createdAt: Date())
        await fixture.api.seed(.init(id: "images", title: "Images", revision: 1, updatedAt: Date(), messages: [message]))
        await fixture.model.select("images")
        let scope = fixture.model.conversationImageScope
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let view = NSHostingView(rootView: VStack {
            AskAttachmentStripView(items: [], screenshot: nil, onPreview: {}, onRemove: { _ in }, attachments: [attachment])
            AskSentFileChip(attachment: attachment)
            AskMessageProvenanceView(message: message)
            AskImageRecoveryCard(model: fixture.model, target: .init(conversationID: "images", runID: "original-run"))
            AskContextImagePreview(source: original)
        }.padding().frame(width: 700, height: 400).environment(\.askContextImageAccess, fixture.model.contextImageAccess(launcher: false)))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains(L("ask.image.previewUnavailable"), in: view) }
        XCTAssertEqual(fixture.model.selected?.messages.first?.image, original)
        XCTAssertEqual(attachment.image, original)
        XCTAssertNil(fixture.model.recoveringImage)
        let retries = await fixture.api.retryModels; XCTAssertTrue(retries.isEmpty)
        scope.invalidate()
    }

    func testViewOwnsRawPixelsAndClearsOnClose() async throws {
        let scope = AskImagePresentationScope(), result = pixels(200)
        let model = AskContextImageModel(decode: { _ in result })
        let view = NSHostingView(rootView: VStack(spacing: 20) {
            Text("Private context preview").font(.headline).foregroundColor(.black)
            AskContextImage(source: "synthetic", model: model) { image in
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Text("Preview unavailable").foregroundColor(.black) }
            }.frame(width: 400, height: 240)
            Text("Original attachment retained").foregroundColor(.black)
        }.padding(24).frame(width: 480, height: 360).background(Color.white)
            .environment(\.askContextImageAccess, access(scope)))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 480, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var rendered: NSBitmapImageRep?
        for _ in 0..<200 {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
               color.blueComponent > 0.6, color.redComponent < 0.5 { rendered = bitmap; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/context-image-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rendered?.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("context.png"))
        window.contentView = nil
        for _ in 0..<100 where model.image != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.image)
    }
}
