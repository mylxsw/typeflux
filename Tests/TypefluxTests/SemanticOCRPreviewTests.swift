import AppKit
import CoreText
import ImageIO
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxMediaProtocol
import TypefluxMediaRuntime

@Suite("Screenshot OCR preview geometry", .exclusiveUIState)
@MainActor
struct SemanticOCRPreviewTests {
    private func fixture(_ root: URL, rotated: Bool) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        for (index, text) in ["Connection failed", "Error ERR-739204", "Request ID REQ-482917"].enumerated() {
            context.textPosition = CGPoint(x: 40, y: 450 - index * 110)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString,
                    46,
                    nil
                ),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])), context)
        }
        var image = try #require(context.makeImage())
        if rotated {
            let turned = try #require(CGContext(data: nil, width: 600, height: 1200, bitsPerComponent: 8,
                                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            turned.translateBy(x: 600, y: 0); turned.rotate(by: .pi / 2)
            turned.draw(image, in: CGRect(x: 0, y: 0, width: 1200, height: 600))
            image = try #require(turned.makeImage())
        }
        let url = root.appendingPathComponent(rotated ? "rotated.jpeg" : "error.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                       (rotated ? "public.jpeg" :
                                                                           "public.png") as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: rotated ? 6 : 1] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The full persistent-hit-to-raster chain shares one versioned fixture.
    @Test(arguments: [false, true])
    // swiftlint:disable:next function_body_length
    func `persisted OCR hit renders real geometry and fallbacks`(rotated: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, rotated: rotated),
            store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(timeout: 20); defer { reader.stop() }
        #expect(try SemanticFileIndexer.index(file.path, scope: semanticScope(root.path), store: store, reader: reader,
                                              encoder: SemanticFixtureEncoder(), media: SemanticFixtureMediaEncoder(),
                                              cancelled: { false },
                                              checkpoint: {}, waitForIdle: {}) == .done)
        let hit = try #require(store.lexicalSearch(text: "ERR-739204", query: .init("ERR-739204"), type: .image,
                                                   scope: semanticScope(root.path), limit: 5, cancelled: { false })
                .first)
        let info = try await AskFilePreviewRenderer.metadata(hit, readText: false)
        #expect(info.version == hit.evidence?.version)
        let worker = MediaWorker(timeout: 3)
        var content = try await AskFilePreviewRenderer.generate(hit, kind: .image,
                                                                pixels: .init(width: 720, height: 900), info: info,
                                                                worker: worker)
        content.fileSize = info.fileSize ?? 0
        content.imageSize = CGSize(width: info.imageWidth ?? 0, height: info.imageHeight ?? 0)
        #expect(content.imageTextLocated == true)
        let displayed = try #require(content.images.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(displayed.width == 720 && displayed.height == 360)
        var needle = hit.evidence
        needle?.text = "ERR-739204"
        let exact = try MediaPreviewDisplay.render(file, pixels: .init(width: 720, height: 900), pdf: false,
                                                   evidence: needle, cancellation: AskSearchCancellation(),
                                                   worker: worker, version: info.version)
        #expect(exact.imageTextLocated == true)
        let boxes = try MediaPreviewOCR.locate(displayed, passage: "ERR-739204").boxes
        #expect(boxes.count == 1)
        let box = try #require(boxes.first)
        #expect(box.midX > 0.15 && box.midX < 0.5 && box.midY > 0.55 && box.midY < 0.66)
        #expect(box.width > 0.15 && box.height > 0.03)
        try verifyPixels(#require(exact.images.first), box: box)
        #expect(try MediaPreviewOCR.locate(displayed, passage: " \n").boxes.isEmpty)
        #expect(try MediaPreviewOCR.locate(displayed, passage: "ERR-NOT-PRESENT").boxes.isEmpty)
        #expect(try MediaPreviewOCR.locate(displayed, passage: "e").boxes.isEmpty,
                "An ambiguous repeated passage must not pick an arbitrary region")
        for variant in ["stale", "missing", "visual"] {
            var changed = hit
            if variant == "stale" {
                changed.evidence?.version = "old"
            }
            if variant == "missing" {
                changed.evidence?.text = "ERR-NOT-PRESENT"
            }
            if variant == "visual" {
                changed.evidence?.segmentKind = "image"
            }
            var fallback = try await AskFilePreviewRenderer.generate(changed, kind: .image,
                                                                     pixels: .init(width: 720, height: 900), info: info,
                                                                     worker: worker)
            fallback.fileSize = info.fileSize ?? 0
            #expect(fallback.imageTextLocated == (variant == "visual" ? nil : false))
            if !rotated, variant == "missing" {
                try await snapshot(fallback, hit: changed, name: "fallback")
            }
        }
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_OCR_PREVIEW_EVIDENCE"] {
            let output = URL(fileURLWithPath: folder)
            try Data(contentsOf: file).write(to: output.appendingPathComponent(file.lastPathComponent))
            try JSONEncoder().encode(MediaTextGeometry(boxes: boxes))
                .write(to: output.appendingPathComponent(rotated ? "rotated-boxes.json" : "boxes.json"))
        }
        if !rotated {
            try await snapshot(content, hit: hit, name: "ocr")
        }
        let target = root.appendingPathComponent("snapshot")
        try MediaWorker.copy(
            .file(file, version: info.version),
            to: target,
            limit: MediaLimits.inputBytes,
            cancelled: { false }
        )
        try Data("replacement".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try MediaWorker.copy(.file(file, version: info.version), to: root.appendingPathComponent("rejected"),
                                 limit: MediaLimits.inputBytes, cancelled: { false })
        }
    }

    private func verifyPixels(_ image: CGImage, box: CGRect) throws {
        let pixels = try #require(image.dataProvider?.data) as Data
        var yellowCount = 0, outside = 0
        for row in 0 ..< 360 {
            for column in 0 ..< 720 {
                let offset = (row * 720 + column) * 4
                if pixels[offset] > 240, pixels[offset + 1] > 200, pixels[offset + 2] < 210 {
                    yellowCount += 1
                    if !box.insetBy(dx: -0.005, dy: -0.005).contains(CGPoint(
                        x: Double(column) / 720, y: 1 - Double(row) / 360
                    )) {
                        outside += 1
                    }
                }
            }
        }
        #expect(yellowCount > 100 && outside == 0, "All visible highlight pixels must lie in the matched region")
    }

    private func snapshot(_ content: AskFilePreviewContent, hit: AskFileHit, name: String) async throws {
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for entry in ["mixed", "files"] {
                let state = AskFilePreviewState()
                state.hit = hit; state.content = content; state.detail = content.detail
                let results = AskQuickResults(apps: [], panes: [], files: [hit], moreFiles: false,
                                              groups: [.files], best: .file(0))
                let item = AskFileSearchPlugin.item(hit)
                #expect(item.fileHit?.evidence == hit.evidence)
                let output = AskPluginOutput(body: hit.name, original: "", meta: [], source: "On this Mac",
                                             actions: [], items: [item])
                let display = AskPluginDisplay(title: "Files", symbol: "doc",
                                               phase: .done(.init(mode: .live, title: "Files"), output))
                let host = NSHostingView(rootView: HStack(spacing: 14) {
                    VStack(alignment: .leading) {
                        Text(entry == "mixed" ? "ERR-739204" : "f ERR-739204").font(.title3).padding()
                        if entry == "mixed" {
                            AskQuickResultsView(results: results, question: "ERR-739204", thumbnails: false,
                                                onRun: { _, _ in }, onHighlight: { _ in })
                        } else {
                            AskPluginResultsView(display: display, question: "ERR-739204", onMain: {},
                                                 onAction: { _ in }, onAskAI: {}, onHighlight: { _ in })
                        }
                        Spacer()
                    }.frame(width: 560)
                    AskFilePreviewView(state: state).frame(width: 380)
                }.padding(14).background(AskTheme.popoverSurface).environment(\.interfaceStyle, .classic))
                let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 982, height: 548),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: appearance)
                host.sizingOptions = []; panel.contentView = host; panel.orderFront(nil)
                defer { panel.orderOut(nil); panel.close() }
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 1000)
                if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_OCR_PREVIEW_EVIDENCE"] {
                    try png
                        .write(to: URL(fileURLWithPath: folder)
                            .appendingPathComponent("\(name)-\(entry)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
        }
    }

    @Test func `geometry protocol rejects invalid and unrelated regions`() throws {
        var request = MediaRequest(operation: .previewImage)
        request.preview = .init(width: 100, height: 80, passage: "ERR-739204")
        var result = MediaPreviewResult(rasters: [.init(width: 100, height: 50)])
        result.textGeometry = .init(boxes: [CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)])
        try result.validate(for: request)
        for box in [CGRect(x: -0.1, y: 0, width: 0.5, height: 0.1), CGRect(x: 0, y: 0, width: -0.5, height: 0.1),
                    CGRect(x: 0, y: 0, width: 1.1, height: 0.1), CGRect(x: 0, y: 0, width: CGFloat.nan, height: 0.1)] {
            result.textGeometry = .init(boxes: [box])
            #expect(throws: MediaFailure.self) { try result.validate(for: request) }
        }
        result.textGeometry = .init(boxes: Array(repeating: CGRect(x: 0, y: 0, width: 1, height: 1), count: 65))
        #expect(throws: MediaFailure.self) { try result.validate(for: request) }
        result.textGeometry = .init(boxes: [])
        request.preview?.passage = nil
        #expect(throws: MediaFailure.self) { try result.validate(for: request) }
        request.operation = .previewPDF; request.preview?.passage = "text"
        #expect(throws: MediaFailure.self) { try result.validate(for: request) }
    }
}

extension SemanticOCRPreviewTests {
    @Test func `selection cancellation and revocation remove located pixels`() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        let scope = AskImagePresentationScope()
        scope.setVisible(true)
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        var first = previewHit("error.png")
        first.evidence = .init(text: "ERR-739204", version: "one", segmentKind: "image-ocr")
        controller.request(first, access: access); clock.advance(0.12)
        loader.completions[0](.init(kind: .image, imageTextLocated: true))
        #expect(controller.state.content?.imageTextLocated == true)
        var second = first; second.evidence?.text = "REQ-482917"
        controller.request(second, access: access)
        #expect(controller.state.content == nil && controller.state.skeleton)
        clock.advance(0.12)
        loader.completions[0](.init(kind: .image, imageTextLocated: true))
        #expect(controller.state.content == nil)
        loader.completions[1](.init(kind: .image, imageTextLocated: true))
        scope.setVisible(false)
        #expect(controller.state.content == nil && !controller.isVisible)
        loader.completions[1](.init(kind: .image, imageTextLocated: true))
        #expect(controller.state.content == nil)
        controller.dismissNow()
    }
}

extension SemanticOCRPreviewTests {
    @Test func `helper composites only requested matched text`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, rotated: false)
        try Data(contentsOf: file).write(to: root.appendingPathComponent("input"))
        for passage in [nil, "ERR-739204", "ERR-NOT-PRESENT"] as [String?] {
            var request = MediaRequest(operation: .previewImage)
            request.preview = .init(width: 720, height: 900, passage: passage)
            let response = try MediaPreviewDecoder.decode(request, directory: root)
            let result = try #require(response.preview)
            #expect(result.rasters.first?.width == 720)
            #expect(result.textGeometry?.boxes.isEmpty == (passage == nil ? nil : passage != "ERR-739204"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("raster-0"))
        }
    }
}
