import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import TypefluxMediaProtocol
import TypefluxMediaRuntime
import XCTest
@testable import Typeflux

private actor WorkflowImageGate {
    var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { count += 1; await withCheckedContinuation { waiters.append($0) } }
    func release() { let old = waiters; waiters = []; old.forEach { $0.resume() } }
}
private struct WorkflowImagePluginFixture: AskLauncherPlugin {
    let image: AskPluginImage
    let id = "fixture", title = "Fixture", symbol = "photo"
    var defaultKeywords: [AskKeyword] { [.init(keyword: "fixture", pluginID: id)] }
    func placeholder(selectionLines: Int?) -> String { "" }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan { .init(mode: .live, title: title) }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan, progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        var output = AskPluginOutput(body: "original", original: "input", meta: [], source: "", actions: [])
        output.image = image; return output
    }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}

private final class WorkflowImageRunnerFixture: AskWorkflowRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    let output: String
    init(_ output: String) { self.output = output }
    func run(_ invocation: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error> {
        lock.lock(); calls += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.finished(.init(exitCode: 0, stdout: output, stderr: "", duration: 0)))
            continuation.finish()
        }
    }
}
private final class WorkflowImageBlockingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return entered }
    func run(_ cancellation: AskSearchCancellation) throws -> Int {
        lock.lock(); entered += 1; lock.unlock()
        release.wait()
        return cancellation.isCancelled ? 1 : 0
    }
}

@MainActor final class WorkflowImageIsolationTests: XCTestCase {
    private func png(_ width: Int = 40, _ height: Int = 20, dpi: Int = 72) -> Data {
        AskAttachmentFixture.encode(AskAttachmentFixture.image(width: width, height: height), type: .png,
            properties: [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi])
    }
    private func entered(_ gate: WorkflowImageGate) async throws {
        for _ in 0..<200 { if await gate.count > 0 { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Work did not enter")
    }
    private func fixture(_ image: AskPluginImage) async throws -> AskTestFixture {
        let fixture = try AskTestFixture()
        fixture.model.owner = fixture.sessionState.owner
        let plugin = WorkflowImagePluginFixture(image: image)
        fixture.model.plugins = AskPluginSession(plugins: [plugin], keywords: { plugin.defaultKeywords })
        fixture.model.plugins.debounce = .zero
        fixture.model.plugins.enter(plugin.defaultKeywords[0])
        fixture.model.plugins.update(text: "image", selection: nil, language: .english)
        for _ in 0..<200 where fixture.model.plugins.output == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(fixture.model.plugins.output)
        return fixture
    }
    private func clipboard() throws -> AskWorkflowImage.Clipboard {
        .init(png: Data([1]), tiff: Data([2]), reservation: try AskToolPixelBudget(limit: 1).acquire(bytes: 1))
    }

    func testProtocolRejectsMixedOperationsUnboundedDimensionsAndCopySizes() throws {
        var metadata = MediaWorkflowImage(format: .png, width: 40, height: 20, scale: 2)
        try metadata.validate(copying: false)
        let inspect = MediaRequest(operation: .inspectWorkflowImage)
        var response = MediaResponse(id: inspect.id); response.workflowImage = metadata
        try response.validate(for: inspect)
        response.id = UUID(); XCTAssertThrowsError(try response.validate(for: inspect)); response.id = inspect.id
        response.generatedImage = .init(mediaType: "image/png", width: 1, height: 1)
        XCTAssertThrowsError(try response.validate(for: inspect)); response.generatedImage = nil
        var other = MediaRequest(id: inspect.id, operation: .image)
        XCTAssertThrowsError(try response.validate(for: other))
        other.operation = .inspectWorkflowImage; other.preview = .init(width: 1, height: 1)
        XCTAssertThrowsError(try other.validate())
        for change in [{ (value: inout MediaWorkflowImage) in value.width = Int.max }, { $0.height = 0 }, { $0.scale = 3 }, { $0.pngBytes = 1 }] {
            var bad = metadata; change(&bad); XCTAssertThrowsError(try bad.validate(copying: false))
        }
        XCTAssertThrowsError(try metadata.validate(copying: true))
        metadata.pngBytes = 10; metadata.tiffBytes = 20; try metadata.validate(copying: true)
        metadata.pngBytes = MediaWorkflowImage.copyBytes; XCTAssertThrowsError(try metadata.validate(copying: true))
        metadata.width = 8193; XCTAssertThrowsError(try metadata.validate(copying: true))
    }

    func testChildPreservesSupportedTypesDPIAndCopyRepresentations() throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for (type, expected) in [(UTType.png, MediaWorkflowFormat.png), (.jpeg, .jpeg), (.gif, .gif), (.tiff, .tiff), (.heic, .heic)] {
            let bytes = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 40, height: 20), type: type,
                properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
            try bytes.write(to: root.appendingPathComponent("input"))
            let response = try MediaWorkflowDecoder.decode(.init(operation: .inspectWorkflowImage), directory: root)
            XCTAssertEqual(response.workflowImage?.format, expected)
            XCTAssertEqual(response.workflowImage?.width, 40)
            XCTAssertFalse(expected.fileExtension.isEmpty)
        }
        try png(dpi: 144).write(to: root.appendingPathComponent("input"))
        let copy = try MediaWorkflowDecoder.decode(.init(operation: .copyWorkflowImage), directory: root)
        XCTAssertEqual(copy.workflowImage?.scale, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("clipboard-png")).count, copy.workflowImage?.pngBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("clipboard-tiff")).count, copy.workflowImage?.tiffBytes)
        for bytes in [Data(), Data([1, 2, 3]), Data(png().prefix(20))] {
            try bytes.write(to: root.appendingPathComponent("input"))
            XCTAssertThrowsError(try MediaWorkflowDecoder.decode(.init(operation: .inspectWorkflowImage), directory: root))
        }
        XCTAssertThrowsError(try MediaWorkflowDecoder.decode(.init(operation: .image), directory: root))
        XCTAssertEqual(MediaWorkflowFormat.webp.fileExtension, "webp")
    }

    func testRealHelperAndChangedContentNeverReusePathOrTimestampAsProof() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picture.png"), bytes = png(dpi: 144)
        try bytes.write(to: file)
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/workflow-image-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let worker = MediaWorker(run: { process, cancelled in
            var process = process; process.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        let image = try await AskWorkflowImage.resolve(file.path, folder: root, cache: root.appendingPathComponent("cache"), home: "/", worker: worker).get()
        XCTAssertEqual(image.width, 20); XCTAssertEqual(image.height, 10)
        let raster = try await AskWorkflowImage.render(image, worker: worker)
        XCTAssertEqual(raster.images.first?.width, 40)
        let copy = try await AskWorkflowImage.clipboard(file, digest: image.digest, worker: worker)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString)); defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(AskQuickResults.copyImage(file, data: copy, to: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .png)); XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), file.absoluteString)
        try png(40, 21).write(to: file)
        do { _ = try await AskWorkflowImage.render(image, worker: worker); XCTFail("Changed source accepted") } catch {}
        do { _ = try await AskWorkflowImage.clipboard(file, digest: image.digest, worker: worker); XCTFail("Changed copy accepted") } catch {}
        await worker.shutdown()
    }

    func testCacheIsBoundedPrivateAndCannotOverwriteCorruptExistingOutput() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = "data:image/png;base64," + png().base64EncodedString(), cache = root.appendingPathComponent("cache")
        let first = try await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: "/", worker: MediaWorker(timeout: 3)).get()
        let directory = first.url.deletingLastPathComponent()
        let permissions = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let again = try await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: "/", worker: MediaWorker(timeout: 3)).get()
        XCTAssertEqual(first, again)
        _ = try await AskWorkflowImage.resolve("data:image/png;base64," + png(41, 20).base64EncodedString(), folder: root, cache: cache, home: "/", worker: MediaWorker(timeout: 3)).get()
        try Data([7]).write(to: first.url)
        let corrupt = await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: "/", worker: MediaWorker(timeout: 3))
        XCTAssertEqual(corrupt, .failure(.notImage)); XCTAssertEqual(try Data(contentsOf: first.url), Data([7]))
        try FileManager.default.removeItem(at: first.url)
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: entry) }
        for n in 0..<128 { try Data().write(to: directory.appendingPathComponent("entry-\(n)")) }
        let full = await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: "/", worker: MediaWorker(timeout: 3))
        XCTAssertEqual(full, .failure(.unavailable)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 128)
    }

    func testSourceBoundsAndDeviceInputsFailWithoutSpawning() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid input dispatched"); throw MediaFailure.unavailable })
        let fifo = root.appendingPathComponent("fifo"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let result = await AskWorkflowImage.resolve(fifo.path, folder: root, cache: root, home: "/", worker: worker)
        XCTAssertEqual(result, .failure(.notImage))
        XCTAssertThrowsError(try AskWorkflowImage.read(URL(string: "https://example.test/x")!))
        let large = root.appendingPathComponent("large"); FileManager.default.createFile(atPath: large.path, contents: Data())
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(MediaWorkflowImage.inputBytes + 1)); try handle.close()
        XCTAssertThrowsError(try AskWorkflowImage.read(large))
        XCTAssertNil(AskWorkflowImage.dataURL("data:image/png;base64," + String(repeating: "a", count: MediaWorkflowImage.inputBytes * 2)))
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return await AskWorkflowImage.resolve("missing", folder: root, cache: root, home: "/", worker: worker) }
        let cancelledResult = await cancelled.value; XCTAssertEqual(cancelledResult, .failure(.unavailable))
    }

    func testCopyPublishesOnceAndRejectsRevocationSelectionChangeAndDuplicates() async throws {
        let image = AskPluginImage(url: URL(fileURLWithPath: "/retained.png"), width: 20, height: 10, digest: "identity")
        for mode in 0..<4 {
            let fixture = try await fixture(image), gate = WorkflowImageGate(), data = try clipboard()
            defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
            var writes = 0, closes = 0
            let prepare: @Sendable (URL, String?) async throws -> AskWorkflowImage.Clipboard = { _, digest in
                XCTAssertEqual(digest, "identity"); await gate.wait(); return data
            }
            fixture.model.copyWorkflowImage(image.url, completed: { closes += 1 }, prepare: prepare, write: { _, _ in writes += 1; return true })
            try await entered(gate)
            fixture.model.copyWorkflowImage(image.url, completed: { XCTFail("Duplicate") }, prepare: prepare)
            switch mode {
            case 1: fixture.model.setLauncherImagesVisible(false)
            case 2: fixture.model.plugins.deactivate()
            case 3: fixture.sessionState.owner = "other"
            default: break
            }
            await gate.release(); await fixture.model.workflowImageCopyTask?.value
            XCTAssertEqual(writes, mode == 0 ? 1 : 0); XCTAssertEqual(closes, mode == 0 ? 1 : 0)
            let count = await gate.count; XCTAssertEqual(count, 1)
        }
    }

    func testCopyFailureLeavesProducedOutputAndNeverFinishesOrRetries() async throws {
        let image = AskPluginImage(url: URL(fileURLWithPath: "/retained.png"), width: 20, height: 10)
        let fixture = try await fixture(image), data = try clipboard()
        defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.copyWorkflowImage(image.url, completed: { XCTFail() }, prepare: { _, _ in throw MediaFailure.unavailable })
        await fixture.model.workflowImageCopyTask?.value
        XCTAssertNotNil(fixture.model.plugins.output?.image)
        fixture.model.copyWorkflowImage(image.url, completed: { XCTFail() }, prepare: { _, _ in data }, write: { _, _ in false })
        await fixture.model.workflowImageCopyTask?.value
        XCTAssertEqual(fixture.model.plugins.output?.body, "original")
        XCTAssertEqual(fixture.model.performPluginAction(.init(kind: .copyImage(image.url), title: "", symbol: "")), .stay)
    }

    func testClipboardRejectsMissingTruncatedSymlinkAndInvalidHeadersWithoutChangingOriginal() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.png"), original = png(); try original.write(to: file)
        for mode in 0..<4 {
            let worker = MediaWorker(run: { process, _ in
                let request = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(process.stdin))
                let directory = AskSecureDirectory(descriptor: dup(process.directoryDescriptor))
                if mode == 1 { try directory.createFile("clipboard-png", data: Data([1])) }
                if mode == 2 {
                    XCTAssertEqual(symlinkat(file.path, directory.descriptor, "clipboard-png"), 0)
                }
                if mode == 3 {
                    try directory.createFile("clipboard-png", data: Data(count: 8))
                    try directory.createFile("clipboard-tiff", data: Data(count: 4))
                }
                var metadata = MediaWorkflowImage(format: .png, width: 40, height: 20, scale: 1)
                metadata.pngBytes = 8; metadata.tiffBytes = 4
                var response = MediaResponse(id: request.id); response.workflowImage = metadata
                return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
            do { _ = try await AskWorkflowImage.clipboard(file, worker: worker); XCTFail("Invalid helper output accepted") } catch {}
            XCTAssertEqual(worker.activeCount, 0)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAdmissionRetainsCancelledUncooperativeWorkUntilItReturns() async throws {
        let gate = WorkflowImageBlockingFixture()
        let first = Task { try await AskWorkflowImage.work { try gate.run($0) } }
        let second = Task { try await AskWorkflowImage.work { try gate.run($0) } }
        for _ in 0..<200 where gate.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.count, 2)
        first.cancel(); second.cancel()
        do { _ = try await AskWorkflowImage.work { _ in XCTFail("Third work admitted"); return 0 }; XCTFail("Unbounded work") } catch {}
        gate.release.signal(); gate.release.signal()
        do { _ = try await first.value; XCTFail("Cancelled work published") } catch {}
        do { _ = try await second.value; XCTFail("Cancelled work published") } catch {}
        let next = try await AskWorkflowImage.work { _ in 3 }; XCTAssertEqual(next, 3)
    }

    func testPostExecutionFailurePreservesFullOutputWithoutProducerReplay() async throws {
        let fixture = try AskWorkflowFixture()
        let folder = try fixture.write("local.image", manifest: AskWorkflowFixture.inline("local.image", keyword: "image", script: "echo", extra: ["output": ["display": "image"]]))
        fixture.store.reload(); fixture.store.trust("local.image")
        let workflow = try XCTUnwrap(fixture.store.workflow("local.image"))
        let original = "data:image/png;base64," + String(repeating: "a", count: 400)
        let runner = WorkflowImageRunnerFixture(original)
        var plugin = AskWorkflowPlugin(workflow: workflow, runner: runner, home: fixture.home.path)
        plugin.resolveImage = { text, actualFolder, _, _ in
            XCTAssertEqual(text, original); XCTAssertEqual(actualFolder.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath()); return .failure(.unavailable)
        }
        let request = AskPluginRequest(text: "in", origin: .argument, keyword: plugin.defaultKeywords[0], options: [:], interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        let output = try await plugin.run(request, plan: plan) { _ in }
        XCTAssertEqual(runner.count, 1); XCTAssertNil(output.image)
        XCTAssertEqual(output.note, L("ask.image.previewUnavailable"))
        XCTAssertLessThan(output.body.count, original.count)
        XCTAssertEqual(output.action(for: .enter)?.kind, .copy(original))

        let gate = WorkflowImageGate()
        plugin.resolveImage = { _, _, _, _ in await gate.wait(); return .failure(.unavailable) }
        let task = Task { try await plugin.run(request, plan: plan) { _ in } }
        try await entered(gate); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled result published") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertEqual(runner.count, 2, "Only the two explicit test invocations run the producer")
    }

    func testCopyNormalizesOrientationAndCacheQuotaNeverEvictsOutputs() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 40, height: 20), type: .jpeg,
            properties: [kCGImagePropertyOrientation: 6])
        try bytes.write(to: root.appendingPathComponent("input"))
        _ = try MediaWorkflowDecoder.decode(.init(operation: .copyWorkflowImage), directory: root)
        let output = try Data(contentsOf: root.appendingPathComponent("clipboard-png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 20)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 40)
        let cache = root.appendingPathComponent("cache"), directory = cache.appendingPathComponent("images")
        let secure = try AskSecureDirectory.openRoot(directory)
        for n in 0..<13 {
            try secure.createFile("large-\(n)", data: Data())
            let file = try FileHandle(forWritingTo: directory.appendingPathComponent("large-\(n)"))
            try file.truncate(atOffset: UInt64(MediaWorkflowImage.inputBytes)); try file.close()
        }
        let result = await AskWorkflowImage.resolve("data:image/png;base64," + png().base64EncodedString(), folder: root, cache: cache, home: "/", worker: MediaWorker(timeout: 3))
        XCTAssertEqual(result, .failure(.unavailable)); XCTAssertEqual(secure.entries(limit: 20).count, 13)
    }

    func testEditorPreparationOwnsItsViewAndLeavesOriginalRunOutput() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = png(80, 40); try original.write(to: root.appendingPathComponent("result.png"))
        let view = NSHostingView(rootView: AskWorkflowImageEditorPreview(name: "result.png", folder: root, worker: MediaWorker(timeout: 3)).frame(width: 300, height: 180).background(Color.white))
        let window = NSWindow(contentRect: .init(x: 50, y: 50, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var ready = false
        for _ in 0..<300 {
            view.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: frame)
            if let color = frame.colorAt(x: frame.pixelsWide / 2, y: frame.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), color.blueComponent > 0.6, color.redComponent < 0.5 { ready = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready)
        view.rootView = AskWorkflowImageEditorPreview(name: "missing.png", folder: root, worker: MediaWorker(timeout: 3)).frame(width: 300, height: 180).background(Color.white)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("result.png")), original)
    }

    func testWorkflowViewShowsRawPixelsAndClearsOnScopeInvalidation() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.png"), original = png(320, 180); try original.write(to: file)
        let image = try await AskWorkflowImage.resolve(file.path, folder: root, cache: root, home: "/", worker: MediaWorker(timeout: 3)).get()
        let scope = AskImagePresentationScope()
        let view = NSHostingView(rootView: VStack(spacing: 16) {
            Text("Workflow image result").font(.headline).foregroundColor(.black)
            AskWorkflowImageView(image: image, size: .init(width: 320, height: 180), worker: MediaWorker(timeout: 3))
            Text("Original file retained • No script replay").foregroundColor(.black)
        }.padding(24).frame(width: 440, height: 300).background(Color.white)
            .environment(\.askContextImageAccess, .init(scope: scope, epoch: scope.epoch, authorize: { true })))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var rendered: NSBitmapImageRep?
        for _ in 0..<300 {
            view.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: frame)
            if let color = frame.colorAt(x: frame.pixelsWide / 2, y: frame.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), color.blueComponent > 0.6, color.redComponent < 0.5 { rendered = frame; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/workflow-image-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rendered?.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("workflow.png"))
        scope.invalidate()
        var cleared = false
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: frame)
            if let color = frame.colorAt(x: frame.pixelsWide / 2, y: frame.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), color.redComponent > 0.5 { cleared = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cleared)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
