import AppKit
import SwiftUI
import TypefluxMediaProtocol
import XCTest
@testable import Typeflux

private actor BadgeCalls {
    var values: [MediaNativeIcon] = []
    func append(_ value: MediaNativeIcon) { values.append(value) }
}

@MainActor final class ContextNativeIconTests: XCTestCase {
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func result() -> AskFilePreviewPDF.Result {
        let context = CGContext(data: nil, width: 56, height: 56, bitsPerComponent: 8, bytesPerRow: 224,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 56, height: 56))
        return .init(images: [context.makeImage()!], numbers: [], pages: 0)
    }
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/context-native-validation")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }

    func testBundleAndExtensionContractsRejectUnboundedOrPathLikeValues() async throws {
        for kind in [MediaNativeIcon.Kind.application, .fileExtension] {
            for value in ["", "../app/name", "name\0hidden", "https://example.test", "日本語", String(repeating: "x", count: 257)] {
                XCTAssertThrowsError(try MediaNativeIcon(kind: kind, value: value).validate())
            }
        }
        try MediaNativeIcon(kind: .application, value: "com.example.Test-App_2").validate()
        try MediaNativeIcon(kind: .application, value: String(repeating: "a", count: 256)).validate()
        try MediaNativeIcon(kind: .fileExtension, value: String(repeating: "a", count: 64)).validate()
        XCTAssertThrowsError(try MediaNativeIcon(kind: .fileExtension, value: String(repeating: "a", count: 65)).validate())
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid target reached child"); throw MediaFailure.unavailable })
        do { _ = try await AskFinderIcon.decode(.init(kind: .application, value: "/Applications/Finder.app"), worker: worker); XCTFail() } catch {}
        XCTAssertThrowsError(try JSONDecoder().decode(MediaNativeIcon.self, from: Data(#"{"kind":"launchApplication","value":"com.apple.finder"}"#.utf8)))
    }

    func testRealHelperResolvesApplicationAndExtensionWithoutOpeningFilesOrApps() async throws {
        let folder = try folder()
        let worker = MediaWorker(run: { process, cancelled in
            var process = process; process.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        for icon in [MediaNativeIcon(kind: .application, value: "com.apple.finder"),
                     .init(kind: .fileExtension, value: "txt"), .init(kind: .fileExtension, value: "unknown-fixture-extension")] {
            let result = try await AskFinderIcon.decode(icon, worker: worker)
            XCTAssertEqual(result.images.count, 1); XCTAssertEqual(result.images.first?.width, 56)
            XCTAssertEqual(result.images.first?.height, 56)
        }
        do { _ = try await AskFinderIcon.decode(.init(kind: .application, value: "test.missing.application.gul399"), worker: worker); XCTFail() } catch {}
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }

    func testPanelSelectionAndHideInvalidateAlreadyDisplayedPixels() async throws {
        let clock = PreviewTestClock(), loader = PreviewTestLoader(), scope = AskImagePresentationScope()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        let raster = result(), model = AskContextImageModel(maximumEdge: 56, decode: { _ in raster })
        controller.request(previewHit("a.txt"), access: access(scope)); clock.advance(0.12)
        XCTAssertFalse(controller.state.imageAccess.allows())
        loader.completions[0](.init(kind: .text, text: "first"))
        let first = controller.state.imageAccess; XCTAssertTrue(first.allows())
        await model.load("type", access: first); XCTAssertNotNil(model.image)
        controller.request(previewHit("b.txt"), access: access(scope))
        XCTAssertNil(model.image); XCTAssertFalse(first.allows())
        clock.advance(0.12); loader.completions[1](.init(kind: .text, text: "second"))
        let second = controller.state.imageAccess; XCTAssertTrue(second.allows())
        await model.load("type", access: second)
        controller.dismissNow(); XCTAssertNil(model.image); XCTAssertFalse(second.allows())
        XCTAssertNil(controller.state.content)
    }

    func testRevocationAndAuthorizationChangeFencePendingContent() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader(), scope = AskImagePresentationScope()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        controller.request(previewHit(), access: access(scope)); clock.advance(0.12)
        scope.invalidate(); loader.completions[0](.init(kind: .text, text: "private"))
        XCTAssertFalse(controller.isVisible); XCTAssertNil(controller.state.content)
        var allowed = true
        let value = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { allowed })
        controller.request(previewHit(), access: value); allowed = false; clock.advance(0.12)
        XCTAssertEqual(loader.requests.count, 1)
        allowed = true; controller.request(previewHit(), access: value); clock.advance(0.12)
        allowed = false; loader.completions[1](.init(kind: .text, text: "private"))
        XCTAssertFalse(controller.isVisible); XCTAssertNil(controller.state.content)
        controller.request(previewHit(), access: value); clock.advance(1)
        XCTAssertEqual(loader.requests.count, 2)
    }

    func testScopeCapacityFailsClosedBeforeLoadingPanel() throws {
        let scope = AskImagePresentationScope(), clock = PreviewTestClock(), loader = PreviewTestLoader()
        let models = (0..<16).map { _ in AskContextImageModel() }
        for model in models { _ = try scope.register(model, epoch: scope.epoch) }
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        controller.request(previewHit(), access: access(scope)); clock.advance(1)
        XCTAssertTrue(loader.requests.isEmpty); XCTAssertFalse(controller.state.imageAccess.allows())
        withExtendedLifetime(models) {}
    }

    func testActualPanelOrderOutAndParentResignClearAccess() async throws {
        _ = NSApplication.shared
        let parent = AskFloatingPanel(contentRect: .init(x: 50, y: 150, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.orderFront(nil)
        defer { parent.close() }
        let clock = PreviewTestClock(), loader = PreviewTestLoader(), scope = AskImagePresentationScope()
        let controller = AskFilePreviewController(loader: loader, clock: clock, reduceMotion: { true })
        controller.attach(to: parent, style: InterfaceStyleObserver(settings: SettingsStore()))
        defer { controller.dismissNow() }
        controller.request(previewHit(), access: access(scope)); clock.advance(0.12)
        loader.completions[0](.init(kind: .text, text: "fixture"))
        let panel = try XCTUnwrap(controller.panel), original = controller.state.imageAccess
        XCTAssertTrue(original.allows()); panel.orderOut(nil)
        XCTAssertFalse(original.allows()); XCTAssertFalse(controller.isVisible); XCTAssertNil(controller.state.content)
        controller.request(previewHit(), access: access(scope)); clock.advance(0.12)
        loader.completions[1](.init(kind: .text, text: "fixture"))
        let reopened = controller.state.imageAccess; XCTAssertTrue(reopened.allows())
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: parent)
        XCTAssertFalse(reopened.allows()); XCTAssertFalse(controller.isVisible)
        controller.request(previewHit(), access: access(scope)); clock.advance(0.12)
        loader.completions[2](.init(kind: .text, text: "fixture"))
        let beforeHide = controller.state.imageAccess; XCTAssertTrue(beforeHide.allows())
        parent.orderOut(nil)
        XCTAssertFalse(beforeHide.allows())
        for _ in 0..<100 where controller.isVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isVisible); XCTAssertNil(controller.state.content)
        parent.orderFront(nil)
        controller.request(previewHit(), access: access(scope)); clock.advance(0.12)
        try XCTUnwrap(loader.completions.last)(.init(kind: .text, text: "fixture"))
        parent.close(); XCTAssertFalse(controller.state.imageAccess.allows())
    }

    func testControllerReleaseCancelsItsScopeAndLoader() async throws {
        let scope = AskImagePresentationScope(), clock = PreviewTestClock(), loader = PreviewTestLoader()
        var controller: AskFilePreviewController? = AskFilePreviewController(loader: loader, clock: clock)
        controller?.request(previewHit(), access: access(scope)); clock.advance(0.12)
        loader.completions[0](.init(kind: .text, text: "fixture"))
        let value = try XCTUnwrap(controller?.state.imageAccess), raster = result()
        let model = AskContextImageModel(maximumEdge: 56, decode: { _ in raster })
        await model.load("type", access: value); XCTAssertNotNil(model.image)
        weak var weakController = controller; controller = nil
        for _ in 0..<100 where model.image != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(weakController); XCTAssertNil(model.image); XCTAssertFalse(value.allows())
        XCTAssertEqual(loader.visible.last, false)
    }

    func testApplicationCallersRenderScopedPixelsAndClearOnRevocation() async throws {
        _ = NSApplication.shared
        let scope = AskImagePresentationScope(), raster = result(), calls = BadgeCalls()
        let token = AskLauncherContext.Token(bundleID: "fixture.application", hasSource: true, title: "Private fixture", restored: true)
        let draft = AskDraft(text: "", source: "Fixture — Document", sourceBundleID: "fixture.application")
        let app = AskContextItem(kind: .source, systemImage: "app", appBundleID: "fixture.application", style: .active, title: "Application")
        let badge = AskContextItem(kind: .selection, systemImage: "text.quote", style: .active, title: "Selection", badge: .app("fixture.application"))
        let provenance = AskContextItem(kind: .selection, systemImage: "text.quote", style: .active, title: "Provenance", sourceAppBundleID: "fixture.application")
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text("Scoped application icons").foregroundStyle(.black)
            HStack(spacing: 16) { AskIconChipFace(item: app); AskIconChipFace(item: badge); AskIconChipFace(item: provenance) }
            AskAttachmentChip(item: app)
            AskLauncherContextTokenView(token: token, action: {})
            AskSourceContextDetails(draft: .constant(draft))
            AskLauncherContextPanel(draft: .constant(draft), screenshotState: .off, restored: false,
                capturing: false, screenshotCapturing: false, setIncluded: { _, _ in }, recapture: {}, refreshTitle: "Refresh")
            AskVoicePanel(live: AskVoiceLive(), listening: false, height: 140)
        }.padding(24).frame(width: 450, height: 720).background(.white)
            .environment(\.askContextImageAccess, access(scope))
            .environment(\.askNativeIconDecoder, { icon in await calls.append(icon); return raster }))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 450, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func capture() throws -> (NSBitmapImageRep, Int) {
            view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            // Compare chroma, since AppKit converts the fixture through the display color profile.
            var blue = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) { for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.blueComponent - color.greenComponent > 0.3, color.redComponent - color.greenComponent > 0.3 { blue += 1 }
            } }
            return (rep, blue)
        }
        var ready: NSBitmapImageRep?
        for _ in 0..<200 {
            let (rep, blue) = try capture(); if blue > 100, await calls.values.count == 7 { ready = rep; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try capture()
        try XCTUnwrap(snapshot.0.representation(using: .png, properties: [:])).write(to: folder().appendingPathComponent("context-native-icons.png"))
        let values = await calls.values
        XCTAssertNotNil(ready, "Visible fixture pixels: \(snapshot.1), decoder calls: \(values.count)")
        XCTAssertEqual(values.count, 7)
        XCTAssertTrue(values.allSatisfy { $0.kind == .application && $0.value == "fixture.application" })
        scope.invalidate()
        for _ in 0..<100 { if try capture().1 == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try capture().1, 0)
    }

    func testExcludedSourceUsesFallbackWithoutLookingUpApplication() async throws {
        _ = NSApplication.shared
        let scope = AskImagePresentationScope(), calls = BadgeCalls(), raster = result()
        let token = AskLauncherContext.Token(bundleID: "private.application", hasSource: true, sourceOff: true)
        let draft = AskDraft(source: "Private source", sourceBundleID: "private.application", sourceOff: true)
        let view = NSHostingView(rootView: VStack {
            AskLauncherContextTokenView(token: token, action: {})
            AskSourceContextDetails(draft: .constant(draft))
            AskLauncherContextPanel(draft: .constant(draft), screenshotState: .off, restored: false,
                capturing: false, screenshotCapturing: false, setIncluded: { _, _ in }, recapture: {}, refreshTitle: "Refresh")
            AskVoicePanel(live: AskVoiceLive(), listening: false, height: 140)
        }.frame(width: 400, height: 600)
            .environment(\.askContextImageAccess, access(scope))
            .environment(\.askNativeIconDecoder, { icon in await calls.append(icon); return raster }))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        defer { scope.invalidate(); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let values = await calls.values; XCTAssertTrue(values.isEmpty)
    }
}
