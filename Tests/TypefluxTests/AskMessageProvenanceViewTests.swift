import AppKit
import SwiftUI
import Testing
import Vision
@testable import Typeflux

/// Join the existing serialized native-event suite so other app-wide monitors
/// cannot consume the clicks used to open a sent attachment's preview.
extension AskComposerInteractionTests {
    @Test func sentProvenanceShowsActualInputsAndSelectionPreview() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let message = AskMessage(id: "sent", role: "user", text: "Question",
                                 selection: "First selected line\nSecond selected line",
                                 source: "Safari — Example", image: "invalid-preview-data", createdAt: Date())
        let window = try await hostProvenance(message)
        defer { window.close() }
        let root = try #require(window.contentView)
        let labels = try provenanceText(in: root).map(\.text).joined(separator: " ")
        #expect(labels.contains("From Safari"))
        #expect(labels.contains("Selected 2 lines"))
        #expect(labels.contains("Full-screen screenshot"))

        let selectionWindow = try await openProvenancePreview(label: "Selected 2 lines", in: window)
        defer { selectionWindow.orderOut(nil) }
        let selectionText = try provenanceText(in: #require(selectionWindow.contentView)).map(\.text).joined(separator: " ")
        #expect(selectionText.contains("First selected line"))
        #expect(selectionText.contains("Second selected line"))
    }

    @Test(arguments: [true, false])
    func sentScreenshotOpensItsImageOrExplainsAnUnavailablePreview(validImage: Bool) async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let imageURL = validImage ? try provenanceImageURL() : "unavailable-image"
        let message = AskMessage(id: "sent", role: "user", text: "Question", image: imageURL, createdAt: Date())
        let window = try await hostProvenance(message)
        defer { window.close() }
        let preview = try await openProvenancePreview(label: "Full-screen screenshot", in: window)
        defer { preview.orderOut(nil) }
        let root = try #require(preview.contentView)
        if validImage {
            #expect(root.bounds.width >= 650)
        } else {
            let labels = try provenanceText(in: root).map(\.text).joined(separator: " ")
            #expect(labels.contains(L("ask.image.previewUnavailable")))
        }
    }

    @Test func messagesWithoutCapturedInputsHaveNoProvenanceRow() async throws {
        let message = AskMessage(id: "sent", role: "user", text: "Question", createdAt: Date())
        let window = try await hostProvenance(message)
        defer { window.close() }
        #expect(try provenanceText(in: #require(window.contentView)).isEmpty)
    }

    private func provenanceImageURL() throws -> String {
        let image = NSImage(size: NSSize(width: 80, height: 50), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private func hostProvenance(_ message: AskMessage) async throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: AskMessageProvenanceView(message: message)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func openProvenancePreview(label: String, in window: NSWindow) async throws -> NSWindow {
        let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        let root = try #require(window.contentView)
        let frame = try #require(try provenanceText(in: root, matching: label).first?.frame)
        let point = root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
        for _ in 0..<10 {
            if let preview = NSApp.windows.first(where: { $0.isVisible && !existingWindows.contains($0.windowNumber) }) {
                try await Task.sleep(for: .milliseconds(100))
                return preview
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let missing: NSWindow? = nil
        return try #require(missing, "Sent attachment preview did not open")
    }

    private func provenanceText(in root: NSView, matching label: String? = nil) throws -> [(text: String, frame: CGRect)] {
        root.layoutSubtreeIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bounds: CGRect
            if let label {
                guard let range = candidate.string.range(of: label),
                      let match = try? candidate.boundingBox(for: range) else { return nil }
                bounds = match.boundingBox
            } else {
                bounds = observation.boundingBox
            }
            let y = root.isFlipped ? 1 - bounds.maxY : bounds.minY
            return (candidate.string, CGRect(x: bounds.minX * root.bounds.width, y: y * root.bounds.height,
                                              width: bounds.width * root.bounds.width, height: bounds.height * root.bounds.height))
        }
    }
}
