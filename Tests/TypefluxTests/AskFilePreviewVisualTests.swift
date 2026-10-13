import AppKit
import AVFoundation
import PDFKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("File preview rendering", .exclusiveUIState)
@MainActor
struct AskFilePreviewVisualTests {
    private func image() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 50, y: 50, width: 540, height: 300))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fillEllipse(in: CGRect(x: 190, y: 95, width: 220, height: 220))
        return try NSImage(cgImage: #require(context.makeImage()), size: NSSize(width: 640, height: 400))
    }

    @Test func `renders every kind in both appearances`() async throws {
        _ = NSApplication.shared
        let image = try image()
        let oldLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(oldLanguage) }
        let examples: [(String, AskFilePreviewContent)] = [
            (
                "sample.png",
                .init(kind: .image, images: [image], fileSize: 40960, imageSize: .init(width: 640, height: 400))
            ),
            ("report.pdf", .init(kind: .pdf, images: [image, image, image], pageCount: 12, fileSize: 81920)),
            (
                "main.swift",
                .init(
                    kind: .text,
                    text: "// Preview sample\nimport Foundation\nlet name = \"Typeflux\"\nlet count = 42\nfunc launch() {\n    print(name)\n}",
                    truncated: false
                )
            ),
            (
                "notes.md",
                .init(
                    kind: .markdown,
                    text: "# Weekly notes\n## Preview window\n- Keyboard navigation\n* Mouse hover\nUse `Command-Y` for **Quick Look**.",
                    truncated: true
                )
            ),
            (
                "budget.csv",
                .init(
                    kind: .table,
                    text: "Item,Amount,Status\nDesign,1200,Done\nDevelopment,3600,In progress\nTesting,800,Planned"
                )
            ),
            ("table.tsv", .init(kind: .table, text: "A\tB\n1\t2", truncated: true)),
            ("proposal.docx", .init(kind: .document, images: [image])),
            ("demo.mov", .init(kind: .video, images: [image], duration: 90)),
            (
                "interview.wav",
                .init(kind: .audio, duration: 213, waveform: (0 ..< 80).map { Float(abs(sin(Double($0) * 0.72))) })
            )
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, example) in examples {
                var content = example
                if content.kind.readsText {
                    content.fileSize = Int64(content.text.utf8.count)
                }
                let state = AskFilePreviewState()
                state.hit = previewHit(name); state.content = content; state.detail = content.detail
                try await render(state, appearance: appearance, name: name)
            }
            let state = AskFilePreviewState()
            state.hit = previewHit("loading.pdf"); state.skeleton = true
            try await render(state, appearance: appearance, name: "skeleton")
            state.hit = nil; state.skeleton = false
            try await render(state, appearance: appearance, name: "empty")
        }
        #expect(AskFilePreviewContent.time(.infinity) == "0:00")
        #expect(AskFilePreviewContent.time(-1) == "0:00")
        #expect(AskFilePreviewContent.time(125) == "2:05")
        #expect(AskFilePreviewContent(kind: .image, images: [image]).cost >= 640 * 400 * 4)
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            #expect(L("launcher.search.preview") != "launcher.search.preview")
            #expect(L("ask.preview.kind.audio") != "ask.preview.kind.audio")
        }
    }

    private func render(_ state: AskFilePreviewState, appearance: NSAppearance.Name, name: String) async throws {
        let window = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 380, height: 520),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: AskFilePreviewView(state: state).environment(\.interfaceStyle, .classic))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { TypefluxNavigationTestSupport.closeWindow(window) }
        try await Task.sleep(for: .milliseconds(35))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= 520, "Preview content must leave the header and footer inside the panel")
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PREVIEW_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
        }
    }

    @Test func `real panel placement reuse and dismissal`() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main?.visibleFrame)
        let parent = NSPanel(contentRect: CGRect(x: screen.minX + 30, y: screen.maxY - 550, width: 600, height: 500),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { TypefluxNavigationTestSupport.closeWindow(parent) }
        let suiteName = "PreviewPlacement-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.interfaceStyle = .classic
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock, reduceMotion: { false })
        defer {
            controller.dismissNow()
            controller.panel.map(TypefluxNavigationTestSupport.closeWindow)
        }
        controller.attach(to: parent, style: InterfaceStyleObserver(settings: settings))
        controller.request(previewHit()); clock.advance(0.12)
        loader.completions[0](.init(kind: .text, text: "Hello"))
        let panel = try #require(controller.panel)
        #expect(panel.parent === parent); #expect(!panel.canBecomeKey); #expect(!panel.canBecomeMain)
        let placement = try #require(AskFilePreviewPlacement.resolve(
            card: parent.frame.insetBy(dx: AskMetrics.launcherGutter, dy: AskMetrics.launcherGutter),
            screens: NSScreen.screens.map(\.visibleFrame)
        ))
        try await SettingsBehaviorTestSupport.wait("Preview panel animation reaching \(placement.frame)") {
            panel.frame == placement.frame && panel.alphaValue == 1
        }
        #expect(panel.frame == placement.frame)
        parent.setFrame(CGRect(x: screen.minX + 35, y: screen.maxY - 250, width: 600, height: 200), display: false)
        controller.updateFrame()
        #expect(panel.frame.height == 320)
        controller.request(nil); clock.advance(0.15)
        clock.advance(0.14)
        try await SettingsBehaviorTestSupport.wait("Preview hide completion") { !panel.isVisible && panel.parent == nil }
        #expect(!panel.isVisible); #expect(panel.parent == nil)
        controller.request(previewHit("again.txt")); clock.advance(0.12)
        loader.completions.last?(.init(kind: .text))
        #expect(controller.panel === panel)
        NotificationCenter.default.post(name: AskQuickLook.willShow, object: nil)
        #expect(!panel.isVisible)
        controller.request(previewHit()); clock.advance(0.12); loader.completions.last?(.init(kind: .text))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: parent)
        #expect(!panel.isVisible)
    }

    @Test func `real text PDF image and audio renderers`() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(base.path))
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = try image()
        let imageURL = root.appendingPathComponent("picture.png")
        let tiff = try #require(picture.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        let document = PDFDocument()
        for index in 0 ..< 5 {
            try document.insert(#require(PDFPage(image: picture)), at: index)
        }
        let pdfURL = root.appendingPathComponent("pages.pdf")
        #expect(document.write(to: pdfURL))
        let textURL = root.appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: textURL)
        let audioURL = root.appendingPathComponent("sound.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 280_000))
            buffer.frameLength = 280_000
            let samples = try #require(buffer.floatChannelData)
            for index in 0 ..< 280_000 {
                samples[0][index] = index < 240_000 ? 0 : 0.5
            }
            try file.write(from: buffer)
        }
        for (url, kind) in [(imageURL, AskFilePreviewKind.image), (pdfURL, .pdf), (textURL, .text), (
            audioURL,
            .audio
        )] {
            var hit = previewHit(url.lastPathComponent); hit.path = url.path
            let info = try await AskFilePreviewRenderer.metadata(hit, readText: kind.readsText)
            #expect(info.fileSize ?? 0 > 0)
            let result = try await AskFilePreviewRenderer.generate(
                hit,
                kind: kind,
                pixels: .init(width: 360, height: 400),
                info: info
            )
            #expect(result.kind == kind)
            if kind == .pdf {
                #expect(result.images.count == 3); #expect(result.pageCount == 5)
                let thumbnail = try await AskFilePreviewRenderer.generate(hit, kind: .document,
                                                                          pixels: .init(width: 360, height: 400),
                                                                          info: info)
                #expect(thumbnail.images.count == 1)
            }
            if kind ==
                .image {
                #expect(result.images.count == 1); #expect(info.imageWidth == 640); #expect(info.imageHeight == 400)
            }
            if kind == .audio {
                #expect(result.waveform.count == 80); #expect(result.duration > 30)
                #expect(result.waveform.allSatisfy { $0 == 0 }, "Samples after the first 30 seconds must be ignored")
            }
            if kind == .text {
                #expect(result.text == "hello")
            }
        }
        await #expect(throws: AskFileReadError.self) {
            try await AskFilePreviewRenderer.generate(previewHit(), kind: .text, pixels: .zero, info: .init())
        }
    }

    @Test func `video frame and invalid media`() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(base.path))
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("movie.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg,
                                                                           AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) ==
            kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 128, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0 ..< 3 {
            for _ in 0 ..< 100 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        var hit = previewHit("movie.mov"); hit.path = url.path
        let result = try await AskFilePreviewRenderer.generate(
            hit,
            kind: .video,
            pixels: .init(width: 128, height: 128),
            info: .init()
        )
        #expect(result.images.count == 1); #expect(result.duration >= 1)
        for kind in [AskFilePreviewKind.pdf, .video, .audio, .document] {
            await #expect(throws: (any Error).self) {
                try await AskFilePreviewRenderer.generate(previewHit("missing." + kind.rawValue), kind: kind,
                                                          pixels: .init(width: 100, height: 100), info: .init())
            }
        }
    }

    @Test func `local image preview latency`() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_PREVIEW_BENCHMARK"] != nil else { return }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(base.path))
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = try image()
        let tiff = try #require(picture.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let loader = AskFilePreviewLoader()
        var times: [Double] = []
        for index in 0 ..< 20 {
            let url = root.appendingPathComponent("sample-\(index).png")
            try data.write(to: url)
            var hit = previewHit(url.lastPathComponent); hit.path = url.path
            let start = ContinuousClock.now
            let result = await withCheckedContinuation { continuation in
                loader.load(hit, pixels: .init(width: 720, height: 900)) { continuation.resume(returning: $0) }
            }
            _ = try #require(result)
            let elapsed = start.duration(to: .now).components
            times.append(120 + Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        let p95 = times.sorted()[18]
        print("Preview benchmark: 20 local PNG paths, 120ms debounce included; p95 = \(p95) ms")
        #expect(p95 <= 250)
    }

    @Test func `cancelled renderers do not publish content`() async {
        for kind in [AskFilePreviewKind.image, .pdf, .document, .audio, .video] {
            let task = Task {
                try await AskFilePreviewRenderer.generate(previewHit("missing.png"), kind: kind,
                                                          pixels: .init(width: 100, height: 100), info: .init())
            }
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
        }
        let reader = Task { try await AskFilePreviewRenderer.metadata(previewHit(), readText: true) }
        reader.cancel()
        await #expect(throws: (any Error).self) { try await reader.value }
    }
}
