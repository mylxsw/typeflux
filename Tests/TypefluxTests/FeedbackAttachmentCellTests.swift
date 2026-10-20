import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackAttachmentCellTests {
    private func thumbnail(_ width: CGFloat, _ height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    @Test func `block sizes follow the attachment kind`() {
        #expect(FeedbackAttachmentCell.size(for: nil) == FeedbackAttachmentCell.fileSize)
        #expect(FeedbackAttachmentCell.size(for: FeedbackAttachment(filename: "a.log", kind: .file, state: .uploading))
            == FeedbackAttachmentCell.fileSize)
        #expect(FeedbackAttachmentCell.size(for: FeedbackAttachment(filename: "a.mp4", kind: .video, state: .uploading))
            == FeedbackAttachmentCell.videoSize)
        // Images without a thumbnail yet get a placeholder size.
        #expect(FeedbackAttachmentCell.size(for: FeedbackAttachment(
            filename: "a.png",
            state: .preparing(progress: nil)
        ))
            == NSSize(width: 240, height: 140))
        // A wide image is scaled to fit the width, a tall one the height, a small one is kept.
        let wide = FeedbackAttachment(filename: "w.png", thumbnail: thumbnail(1000, 500), state: .uploading)
        #expect(FeedbackAttachmentCell.size(for: wide) == NSSize(width: 360, height: 180))
        let tall = FeedbackAttachment(filename: "t.png", thumbnail: thumbnail(400, 1100), state: .uploading)
        #expect(FeedbackAttachmentCell.size(for: tall) == NSSize(width: 120, height: 220))
        let small = FeedbackAttachment(filename: "s.png", thumbnail: thumbnail(200, 100), state: .uploading)
        #expect(FeedbackAttachmentCell.size(for: small) == NSSize(width: 200, height: 100))
    }

    @Test func `the cell reads the current attachment each time`() {
        var attachment = FeedbackAttachment(filename: "a.mp4", kind: .video, state: .uploading)
        let id = attachment.id
        let cell = FeedbackAttachmentCell(attachmentID: id) { $0 == id ? attachment : nil }
        #expect(cell.cellSize().width == FeedbackAttachmentCell.videoSize.width)
        attachment.kind = .file
        #expect(cell.cellSize().width == FeedbackAttachmentCell.fileSize.width)
        #expect(!cell.wantsToTrackMouse())
        #expect(cell.cellBaselineOffset() == .zero)
    }

    @Test func `durations are formatted as minutes and seconds`() {
        #expect(FeedbackAttachmentCell.formattedDuration(0) == "0:00")
        #expect(FeedbackAttachmentCell.formattedDuration(65.4) == "1:05")
        #expect(FeedbackAttachmentCell.formattedDuration(600) == "10:00")
        #expect(FeedbackAttachmentCell.formattedDuration(-3) == "0:00")
    }

    @Test func `the remove button is a small circle on pictures and at the end of file rows`() {
        let frame = NSRect(x: 10, y: 20, width: 300, height: 100)
        for kind in [FeedbackAttachmentKind.image, .video] {
            let button = FeedbackAttachmentCell.removeButtonRect(in: frame, kind: kind)
            #expect(button.size == NSSize(width: TFControlSize.small.height, height: TFControlSize.small.height))
            #expect(button.maxX < frame.maxX && button.minY > frame.minY && button.midY < frame.midY)
            #expect(frame.contains(button))
        }
        let row = FeedbackAttachmentCell.removeButtonRect(in: frame, kind: .file)
        #expect(row.midY == frame.midY && row.maxX < frame.maxX && frame.contains(row))
    }

    @Test func `only failed and refused states are errors`() {
        #expect(FeedbackAttachmentState.failed("x").isError && FeedbackAttachmentState.rejected("x").isError)
        for state in [FeedbackAttachmentState.preparing(progress: 0.5), .uploading, .uploaded("u")] {
            #expect(!state.isError)
        }
    }

    @Test(arguments: [FeedbackAttachmentKind.image, .video, .file])
    func `every kind draws in every state`(kind: FeedbackAttachmentKind) throws {
        let states: [FeedbackAttachmentState] = [
            .preparing(progress: nil), .preparing(progress: 0.4), .uploading, .uploaded("https://cdn/x"),
            .failed("offline"), .rejected("too large")
        ]
        for state in states {
            let attachment = FeedbackAttachment(
                filename: "name.\(kind == .file ? "log" : kind == .video ? "mp4" : "jpg")", kind: kind,
                sizeBytes: 2048, durationSeconds: kind == .video ? 75 : nil,
                thumbnail: thumbnail(300, 200), state: state
            )
            let cell = FeedbackAttachmentCell(attachmentID: attachment.id) { _ in attachment }
            let size = cell.cellSize()
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            cell.draw(withFrame: NSRect(origin: .zero, size: size), in: nil)
            NSGraphicsContext.restoreGraphicsState()
            #expect(rep.colorAt(x: Int(size.width) / 2, y: Int(size.height) / 2) != nil)
        }
    }

    @Test func `a cell for an unknown attachment draws nothing`() {
        let cell = FeedbackAttachmentCell(attachmentID: UUID()) { _ in nil }
        cell.draw(withFrame: NSRect(x: 0, y: 0, width: 100, height: 50), in: nil)
        #expect(cell.cellSize() == NSSize(width: 360, height: 64))
    }

    @Test func `state flags drive submit and progress`() {
        #expect(FeedbackAttachmentState.uploaded("u").isReady && !FeedbackAttachmentState.uploaded("u")
            .isBlockingSubmit)
        for state in [FeedbackAttachmentState.preparing(progress: nil), .uploading] {
            #expect(state.isInProgress && state.isBlockingSubmit && !state.isReady && state.uploadedURL == nil)
        }
        for state in [FeedbackAttachmentState.failed("x"), .rejected("y")] {
            #expect(!state.isInProgress && state.isBlockingSubmit)
        }
        #expect(FeedbackAttachmentState.uploaded("u").uploadedURL == "u")
    }
}
