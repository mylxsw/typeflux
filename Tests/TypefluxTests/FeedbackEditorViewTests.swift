import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackEditorViewTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func makeModel() -> (FeedbackWindowModel, FeedbackServicesStub) {
        let services = FeedbackServicesStub()
        return (FeedbackWindowModel(services: services, defaultContact: { "" }), services)
    }

    private func sampleFile(_ name: String, bytes: Int = 16) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    @Test func `the editor registers its text view with the model and routes files and screenshots`() async throws {
        let (model, _) = makeModel()
        let toolbar = FeedbackToolbarState()
        try await UI.withFixture { _ in
            try await UI
                .withWindow(FeedbackEditorView(model: model, toolbar: toolbar), width: 500, height: 300) { _, _ in
                    let textView = try #require(model.editor.textView)
                    #expect(textView.placeholder == L("feedback.direct.contentPlaceholder"))

                    try textView.onFiles?([sampleFile("a.log")])
                    #expect(model.attachments.map(\.filename) == ["a.log"])
                    textView.onImageData?(Data([1, 2, 3]))
                    #expect(model.attachments.count == 2)
                    #expect(model.attachments[1].filename.hasPrefix("screenshot-"))
                }
        }
    }

    @Test func `screenshots are named by time`() {
        let name = FeedbackEditorView.screenshotName()
        #expect(name.range(of: #"^screenshot-\d{4}-\d{2}-\d{2}-\d{6}\.png$"#, options: .regularExpression) != nil)
    }

    @Test(arguments: [FeedbackAttachmentKind.image, .video, .file])
    func `mouse clicks remove the targeted attachment in every upload state`(kind: FeedbackAttachmentKind) async throws {
        let states: [FeedbackAttachmentState] = [
            .preparing(progress: nil), .uploading, .uploaded("https://example.com/file"),
            .failed("offline"), .rejected("too large")
        ]
        try await UI.withFixture { _ in
            for state in states {
                let (model, _) = makeModel()
                try await UI.withWindow(
                    FeedbackEditorView(model: model, toolbar: FeedbackToolbarState()), width: 500, height: 300
                ) { window, _ in
                    let view = try #require(model.editor.textView)
                    view.insertText("Keep this text\n", replacementRange: view.selectedRange())
                    let retained = model.beginAttachment(filename: "keep.log", kind: .file, originalSize: 1)
                    let removed = model.beginAttachment(filename: "remove", kind: kind, originalSize: 1)
                    model.update(id: removed) { $0.state = state }
                    let layout = try #require(view.layoutManager)
                    let container = try #require(view.textContainer)
                    layout.ensureLayout(for: container)
                    let storage = try #require(view.textStorage)
                    var characterRange: NSRange?
                    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
                        value, range, _ in
                        if (value as? FeedbackTextAttachment)?.attachmentID == removed {
                            characterRange = range
                        }
                    }
                    let range = try #require(characterRange)
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    let frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
                        .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
                    let button = FeedbackAttachmentCell.removeButtonRect(
                        in: frame.insetBy(dx: 0, dy: 4), kind: kind
                    )
                    #expect(view.attachmentRemovalTarget(at: NSPoint(x: frame.minX + 10, y: frame.midY)) == nil)
                    #expect(view.attachmentRemovalTarget(at: NSPoint(x: frame.maxX + 20, y: frame.midY)) == nil)
                    #expect(view.attachmentRemovalTarget(at: NSPoint(x: 0, y: 0)) == nil)

                    // Scrolling changes window coordinates, while TextKit frames remain in document coordinates.
                    view.scroll(NSPoint(x: 0, y: max(0, button.midY - 80)))
                    let location = view.convert(NSPoint(x: button.midX, y: button.midY), to: nil)
                    let event = try #require(NSEvent.mouseEvent(
                        with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                    ))
                    view.mouseDown(with: event)

                    #expect(model.attachments.map(\.id) == [retained])
                    #expect(view.attachmentIDs == [retained])
                    #expect(view.string.hasPrefix("Keep this text\n"))
                }
            }
        }
    }

    private func makeCoordinator(
        _ model: FeedbackWindowModel,
        _ toolbar: FeedbackToolbarState,
        text: String
    ) -> (FeedbackEditorView.Coordinator, FeedbackTextView) {
        let view = FeedbackTextView()
        view.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: FeedbackRichText.baseAttributes
        ))
        model.editor.textView = view
        let coordinator = FeedbackEditorView.Coordinator(model: model, toolbar: toolbar)
        coordinator.textView = view
        view.delegate = coordinator
        return (coordinator, view)
    }

    @Test func `the toolbar follows the selection`() {
        let (model, _) = makeModel()
        let toolbar = FeedbackToolbarState()
        let (coordinator, view) = makeCoordinator(model, toolbar, text: "hello world")
        let note = Notification(name: NSTextView.didChangeSelectionNotification)

        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleInline(.bold)
        view.toggleInline(.strikethrough)
        coordinator.textViewDidChangeSelection(note)
        #expect(toolbar.bold && toolbar.strikethrough && !toolbar.italic)

        view.setSelectedRange(NSRange(location: 6, length: 0))
        coordinator.textViewDidChangeSelection(note)
        #expect(!toolbar.bold && !toolbar.strikethrough && toolbar.block == nil)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.toggleBlock(.quote)
        coordinator.textViewDidChangeSelection(note)
        #expect(toolbar.block == .quote)
    }

    @Test func `typing updates the model and shortcuts are intercepted`() {
        let (model, _) = makeModel()
        let (coordinator, view) = makeCoordinator(model, FeedbackToolbarState(), text: "")

        view.insertText("hello", replacementRange: view.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(model.hasText)

        let marker = makeCoordinator(model, FeedbackToolbarState(), text: "-")
        marker.1.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!marker.0.textView(
            marker.1,
            shouldChangeTextIn: NSRange(location: 1, length: 0),
            replacementString: " "
        ))
        #expect(marker.0.textView(
            marker.1,
            shouldChangeTextIn: NSRange(location: 1, length: 0),
            replacementString: "x"
        ))
        #expect(marker.0.textView(
            marker.1,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: nil
        ))
    }

    @Test func `return is handled only for list and heading lines`() {
        let (model, _) = makeModel()
        let (coordinator, view) = makeCoordinator(model, FeedbackToolbarState(), text: "")
        #expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        view.toggleBlock(.bulletList)
        #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }

    @Test func `clicking a failed block retries it and double clicking needs a local file`() async throws {
        let (model, services) = makeModel()
        let (coordinator, view) = makeCoordinator(model, FeedbackToolbarState(), text: "")
        services.uploadError = FeedbackAPIError.networkError("offline")
        try model.addFiles([sampleFile("a.log")])
        for _ in 0 ..< 400 {
            if case .failed = model.attachments.first?.state {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let attachment = try #require(model.attachments.first)
        guard case .failed = attachment.state else {
            Issue.record("expected a failed upload")
            return
        }
        let index = try #require(view.string.utf16.firstIndex { $0 == 0xFFFC }).utf16Offset(in: view.string)
        let cell = FeedbackAttachmentCell(attachmentID: attachment.id) { _ in nil }

        services.uploadError = nil
        coordinator.textView(view, clickedOn: cell, in: NSRect(x: 0, y: 0, width: 300, height: 60), at: index)
        for _ in 0 ..< 400 where !(model.attachments.first?.state.isReady ?? false) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.attachments.first?.state.isReady == true)

        // Neither click does anything on text, and a pasted image has no file to open.
        coordinator.textView(view, clickedOn: cell, in: .zero, at: 0)
        coordinator.textView(view, doubleClickedOn: cell, in: .zero, at: 0)
        model.addImageData(Data([1]), filename: "pasted.png")
        let second = view.attachmentIDs.last
        #expect(second != nil)
        coordinator.textView(view, doubleClickedOn: cell, in: .zero, at: view.string.utf16.count - 2)
    }

    @Test func `live services prepare images and report no sign-in`() async throws {
        try await UI.withFixture { _ in
            let services = LiveFeedbackServices()
            let image = NSImage(size: NSSize(width: 64, height: 32))
            image.lockFocus()
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 64, height: 32).fill()
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))

            let prepared = try await services.prepareImage(data: png, filename: "shot.png")
            #expect(prepared.filename == "shot.jpg" && prepared.contentType == "image/jpeg")

            let credential = await services.credential()
            #expect(credential == nil)
        }
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackWindowCaptureTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func `a captured region is added to the body and the window comes back`() async throws {
        let png = try pngData()
        try await UI.withFixture { settings in
            let model = FeedbackWindowModel(services: FeedbackServicesStub(), defaultContact: { "" })
            let controller = FeedbackWindowController(model: model, captureRegion: { png })
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }

            controller.captureScreenshot()
            #expect(controller.window?.isVisible == false, "the window hides while the region is selected")
            try await UI.wait { model.attachments.count == 1 }
            #expect(controller.window?.isVisible == true)
            #expect(model.attachments[0].filename.hasPrefix("screenshot-"))
        }
    }

    @Test func `a cancelled selection adds nothing`() async throws {
        try await UI.withFixture { settings in
            let model = FeedbackWindowModel(services: FeedbackServicesStub(), defaultContact: { "" })
            let controller = FeedbackWindowController(model: model, captureRegion: { nil })
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }

            controller.captureScreenshot()
            try await UI.wait { controller.window?.isVisible == true }
            #expect(model.attachments.isEmpty)
        }
    }

    @Test func `capturing is refused while the attachment limit is reached`() async throws {
        try await UI.withFixture { settings in
            let model = FeedbackWindowModel(services: FeedbackServicesStub(), defaultContact: { "" })
            let controller = FeedbackWindowController(model: model, captureRegion: { nil })
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }
            for index in 0 ..< FeedbackAttachmentPolicy.maxAttachmentCount {
                model.addImageData(Data([1]), filename: "p\(index).png")
            }
            controller.captureScreenshot()
            #expect(controller.window?.isVisible == true)
        }
    }
}

struct FeedbackVideoCompressorTests {
    /// Writes a short H.264 clip so the compressor has a real asset to work on.
    private func makeVideo(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-src-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< seconds * 10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 128, 96, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(frame * 7 % 255), CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "the sample video must be written")
        return url
    }

    @Test func `a recording is compressed to an mp4 with its duration and a cover`() async throws {
        let source = try await makeVideo(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let progress = ProgressLog()

        let prepared = try await FeedbackVideoCompressor.compress(url: source) { progress.record($0) }

        #expect(prepared.kind == .video && prepared.contentType == "video/mp4")
        #expect(prepared.filename.hasSuffix(".mp4") && !prepared.data.isEmpty)
        #expect(Int64(prepared.data.count) <= FeedbackAttachmentPolicy.maxVideoBytes)
        #expect((prepared.durationSeconds ?? 0) > 1.5)
        #expect(prepared.thumbnail != nil)
        #expect(progress.last == 1)
    }

    @Test func `a file that is not a video is refused`() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mov")
        try Data("not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: FeedbackMediaError.videoUnreadable) {
            try await FeedbackVideoCompressor.compress(url: url) { _ in }
        }
    }

    @Test func `a cancelled export stops`() async throws {
        let source = try await makeVideo(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let task = Task {
            try await FeedbackVideoCompressor.compress(url: source) { _ in }
        }
        task.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.withLock { values.append(value) }
    }

    var last: Double? {
        lock.withLock { values.last }
    }
}
