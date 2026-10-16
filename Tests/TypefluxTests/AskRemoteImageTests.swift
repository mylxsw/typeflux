import AppKit
import SwiftUI
import TypefluxMediaProtocol
import XCTest
@testable import Typeflux

private struct RemoteTransport: AskImageTransport {
    let operation: @Sendable (URLRequest, Int) async throws -> Data
    func send(_ request: URLRequest, limit: Int) async throws -> Data { try await operation(request, limit) }
}
private actor RemoteGate {
    var count = 0
    private var waiters: [CheckedContinuation<Data, Never>] = []
    func wait() async -> Data {
        count += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release() { let old = waiters; waiters = []; for waiter in old { waiter.resume(returning: Data([1])) } }
}

@MainActor final class AskRemoteImageTests: XCTestCase {
    let asset = AskGeneratedImage(assetId: "stable", url: "https://image.test/result?signature=private")
    func pixels(_ width: Int = 16) -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: width, height: 12)], numbers: [], pages: 1)
    }
    func access(_ scope: AskRemoteImageScope) -> AskRemoteImageAccess { .init(scope: scope, epoch: scope.epoch, authorize: { true }) }
    func loader(_ result: AskFilePreviewPDF.Result? = nil) -> AskRemoteImageLoader {
        let result = result ?? pixels()
        return .init(transport: RemoteTransport { request, limit in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertEqual(limit, 16 * 1024 * 1024)
            return Data([1])
        }, decode: { _ in result })
    }
    private func entered(_ gate: RemoteGate, _ count: Int) async throws {
        for _ in 0..<200 {
            if await gate.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("work did not enter")
    }

    func testSuccessfulProjectionIsClearedOnScopeRevocationAndCanReopen() async throws {
        let scope = AskRemoteImageScope(), model = AskRemoteImageModel(loader: loader())
        await model.load(asset, access: access(scope))
        XCTAssertNotNil(model.image); XCTAssertFalse(model.unavailable)
        let old = access(scope)
        scope.setVisible(false)
        XCTAssertNil(model.image); XCTAssertFalse(old.allows())
        await model.load(asset, access: old)
        XCTAssertNil(model.image)
        scope.setVisible(true); scope.setVisible(true)
        await model.load(asset, access: access(scope))
        XCTAssertNotNil(model.image)
        scope.invalidate(); XCTAssertNil(model.image)
    }

    func testRevocationDuringDownloadCancelsWithoutDecodingOrPublishing() async throws {
        let gate = RemoteGate(), scope = AskRemoteImageScope()
        let model = AskRemoteImageModel(loader: .init(transport: RemoteTransport { _, _ in await gate.wait() }, decode: { _ in
            XCTFail("cancelled download must not decode"); throw MediaFailure.unavailable
        }))
        let operation = Task { await model.load(asset, access: access(scope)) }
        try await entered(gate, 1)
        scope.invalidate(); await gate.release(); await operation.value
        XCTAssertNil(model.image); XCTAssertFalse(model.unavailable)
    }

    func testChangedAuthorizationAfterDecodeWithholdsPixelsAndKeepsReference() async throws {
        let gate = RemoteGate(), scope = AskRemoteImageScope(), result = pixels()
        var authorized = true
        let access = AskRemoteImageAccess(scope: scope, epoch: scope.epoch, authorize: { authorized })
        let model = AskRemoteImageModel(loader: .init(transport: RemoteTransport { _, _ in Data([1]) }, decode: { _ in
            _ = await gate.wait(); return result
        }))
        let operation = Task { await model.load(asset, access: access) }
        try await entered(gate, 1); authorized = false
        await gate.release(); await operation.value
        XCTAssertNil(model.image); XCTAssertFalse(model.unavailable)
        XCTAssertEqual(asset.safeURL?.query, "signature=private")
    }

    func testOldDecoderCannotOverwriteOrCancelNewSelection() async throws {
        let gate = RemoteGate(), scope = AskRemoteImageScope(), result = pixels()
        let model = AskRemoteImageModel(loader: .init(transport: RemoteTransport { _, _ in Data([1]) }, decode: { _ in
            _ = await gate.wait(); return result
        }))
        let old = Task { await model.load(asset, access: access(scope)) }
        try await entered(gate, 1)
        model.cancel()
        let new = Task { await model.load(.init(assetId: "new", url: "https://image.test/new"), access: access(scope)) }
        try await entered(gate, 2)
        await gate.release(); await old.value; await new.value
        XCTAssertNotNil(model.image); XCTAssertFalse(model.unavailable)
        model.cancel()
    }

    func testGlobalAdmissionRetainsCancelledWorkUntilItActuallyReturns() async throws {
        let gate = RemoteGate(), result = pixels()
        let loader = AskRemoteImageLoader(transport: RemoteTransport { _, _ in await gate.wait() }, decode: { _ in result })
        let first = Task { try await loader.load(asset) }, second = Task { try await loader.load(asset) }
        try await entered(gate, 2); first.cancel()
        do { _ = try await loader.load(asset); XCTFail("third download admitted") }
        catch { XCTAssertEqual(error as? MediaFailure, .unavailable) }
        let count = await gate.count; XCTAssertEqual(count, 2)
        await gate.release()
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await second.value
        _ = try await self.loader().load(asset)
    }

    func testPixelReservationPrecedesDownloadAndSurvivesLateWork() async throws {
        let gate = RemoteGate(), scope = AskRemoteImageScope(), result = pixels()
        let budget = AskToolPixelBudget(limit: 1600 * 1600 * 4)
        let loader = AskRemoteImageLoader(transport: RemoteTransport { _, _ in await gate.wait() }, decode: { _ in result })
        let first = AskRemoteImageModel(loader: loader, budget: budget)
        let task = Task { await first.load(asset, access: access(scope)) }
        try await entered(gate, 1); first.cancel()
        let second = AskRemoteImageModel(loader: self.loader(), budget: budget)
        await second.load(asset, access: access(scope)); XCTAssertTrue(second.unavailable)
        await gate.release(); await task.value
        await second.load(asset, access: access(scope)); XCTAssertNotNil(second.image)
        second.cancel()
    }

    func testInputResponseAndRasterLimitsFailClosedWithoutRetries() async throws {
        for invalid in [AskGeneratedImage(assetId: "", url: asset.url), .init(assetId: String(repeating: "x", count: 1025), url: asset.url),
                        .init(assetId: "a", url: String(repeating: "x", count: 16385)), .init(assetId: "a", url: "http://image.test/x")] {
            XCTAssertNil(AskRemoteImageLoader.eligible(invalid))
            do { _ = try await loader().load(invalid); XCTFail() } catch {}
        }
        for data in [Data(), Data(repeating: 0, count: AskRemoteImageLoader.maximumBytes + 1)] {
            let invalid = AskRemoteImageLoader(transport: RemoteTransport { _, _ in data }, decode: { _ in XCTFail(); throw MediaFailure.unreadable })
            do { _ = try await invalid.load(asset); XCTFail() } catch {}
        }
        for result in [AskFilePreviewPDF.Result(images: [], numbers: [], pages: 0), pixels(1601),
                       .init(images: pixels().images + pixels().images, numbers: [], pages: 1)] {
            do { _ = try await loader(result).load(asset); XCTFail() }
            catch { XCTAssertEqual(error as? MediaFailure, .invalidProtocol) }
        }
        let scope = AskRemoteImageScope()
        let model = AskRemoteImageModel(loader: .init(transport: RemoteTransport { _, _ in throw URLError(.timedOut) }))
        await model.load(asset, access: access(scope)); XCTAssertTrue(model.unavailable); XCTAssertNil(model.image)
        await model.load(asset, access: .init()); XCTAssertFalse(model.unavailable)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load(asset, access: access(scope)) }
        await cancelled.value; XCTAssertFalse(model.unavailable)
    }

    func testObserverCapPrunesReleasedViewsAndRejectsStaleEpoch() throws {
        let scope = AskRemoteImageScope(), epoch = scope.epoch
        var models: [AskRemoteImageModel] = []
        for _ in 0..<16 { let model = AskRemoteImageModel(); models.append(model); _ = try scope.register(model, epoch: epoch) }
        XCTAssertThrowsError(try scope.register(AskRemoteImageModel(), epoch: epoch))
        models.removeAll()
        _ = try scope.register(AskRemoteImageModel(), epoch: epoch)
        scope.invalidate()
        XCTAssertThrowsError(try scope.register(AskRemoteImageModel(), epoch: epoch))
    }

    func testRealHelperDetectsOriginalTypeAndRejectsMalformedBytes() async throws {
        let data = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 20, height: 12), type: .png)
        let loader = AskRemoteImageLoader(transport: RemoteTransport { _, _ in data })
        let result = try await loader.load(asset)
        XCTAssertEqual(result.images.first?.width, 20); XCTAssertEqual(result.images.first?.height, 12)
        for malformed in [Data([1, 2, 3]), Data(data.prefix(20))] {
            do { _ = try await AskRemoteImageLoader(transport: RemoteTransport { _, _ in malformed }).load(asset); XCTFail() } catch {}
        }
    }

    func testRemoteRedirectsAreBoundedHTTPSGETAndNeverForwardCredentials() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://image.test/x")!, task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let policy = AskImageRedirectPolicy(maximumRedirects: 100)
        var request = URLRequest(url: URL(string: "https://cdn.test/image?signed=yes")!)
        request.setValue("secret", forHTTPHeaderField: "Authorization"); request.setValue("private", forHTTPHeaderField: "Cookie")
        for _ in 0..<3 {
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                XCTAssertEqual($0?.url, request.url); XCTAssertNil($0?.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil($0?.value(forHTTPHeaderField: "Cookie"))
            }
        }
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { XCTAssertNil($0) }
        for target in ["http://cdn.test/x", "https://user:secret@cdn.test/x", "file:///tmp/x", "https://cdn.test/" + String(repeating: "x", count: 16385)] {
            AskImageRedirectPolicy(maximumRedirects: 3).urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)) { XCTAssertNil($0) }
        }
        request.httpMethod = "POST"
        AskImageRedirectPolicy(maximumRedirects: 3).urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { XCTAssertNil($0) }
    }

    func testViewOwnsLoadingPixelsLinksAndCloseCleanup() async throws {
        let scope = AskRemoteImageScope(), model = AskRemoteImageModel(loader: loader())
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
            Text("Generated image").font(.headline).foregroundColor(.black)
            AskRemoteImageView(asset: asset, model: model)
            AskRemoteImageView(asset: .init(assetId: "link-only", url: asset.url), enabled: false)
        }.padding(24).frame(width: 540, height: 420).background(Color.white).environment(\.askRemoteImageAccess, access(scope)))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 540, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where model.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.image)
        // Model readiness precedes SwiftUI's next rendered frame. Wait for visible pixels,
        // not an arbitrary delay or only the published image, before taking the fixture.
        var rendered: NSBitmapImageRep?
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: frame)
            if let color = frame.colorAt(x: frame.pixelsWide / 2, y: frame.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
               color.blueComponent > 0.6, color.redComponent < 0.5 {
                rendered = frame; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bitmap = try XCTUnwrap(rendered, "ready pixels must actually render")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/remote-image-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("remote.png"))
        window.contentView = nil
        for _ in 0..<100 where model.image != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.image)
    }

    func testOutputGroupBoundsPreviewAttemptsAndRetainsAllAssetReferences() async throws {
        let scope = AskRemoteImageScope(), calls = RemoteRequests()
        let assets = (0..<12).map { AskGeneratedImage(assetId: "asset-\($0)", url: "https://image.test/\($0)") }
        let outputs = AskRunOutputs(generatedImages: assets)
        let loader = AskRemoteImageLoader(transport: RemoteTransport { request, _ in
            calls.record(request.url!.lastPathComponent)
            throw URLError(.timedOut)
        })
        let view = NSHostingView(rootView: AskRunOutputsView(outputs: outputs, remoteImages: loader)
            .environment(\.askRemoteImageAccess, access(scope)))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<100 where calls.values.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(calls.values.isEmpty)
        XCTAssertLessThanOrEqual(calls.values.count, 8)
        XCTAssertTrue(calls.values.allSatisfy { (Int($0) ?? 99) < 8 })
        XCTAssertEqual(outputs.generatedImages, assets)
        scope.invalidate()
    }

    func testProductionAccessRejectsSelectionAccountTokenDeletionAndHiddenWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: defaults)),
            artifactStore: AskArtifactStore(storageURL: root.appendingPathComponent("artifacts")))
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        var account: (owner: String, token: String)? = ("owner", "token")
        let api = AskTestAPI()
        await api.seed(AskConversation(id: "conversation", title: "Images", revision: 1, updatedAt: Date(), messages: []))
        let model = AskConversationModel(api: api, cache: cache, tools: tools, capture: AskTestCapture(), deviceId: "test",
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults, session: { account })
        defer { model.resetSession() }
        XCTAssertFalse(model.remoteImageAccess.allows())
        await model.select("conversation")
        let old = model.remoteImageAccess; XCTAssertTrue(old.allows())
        model.selectionGeneration = UUID(); XCTAssertFalse(old.allows())
        let fresh = model.remoteImageAccess
        account = ("other", "token"); XCTAssertFalse(fresh.allows())
        account = ("owner", "other"); XCTAssertFalse(fresh.allows())
        account = nil; XCTAssertFalse(fresh.allows())
        account = ("owner", "token"); XCTAssertTrue(fresh.allows())
        model.setRemoteImagesVisible(false); XCTAssertFalse(fresh.allows())
        model.setRemoteImagesVisible(true); XCTAssertTrue(model.remoteImageAccess.allows())
        model.invalidateRemoteImages()
        await model.delete("conversation"); XCTAssertFalse(model.remoteImageAccess.allows())
    }
}

private final class RemoteRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    var values: [String] { lock.withLock { requests } }
    func record(_ value: String) { lock.withLock { requests.append(value) } }
}
