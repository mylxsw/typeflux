import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// What a scrolling capture records: a region of one display, live.
struct ScrollCaptureRegion: Equatable {
    var displayID: CGDirectDisplayID
    var displayFrame: CGRect
    var scale: CGFloat
    /// In global Quartz points, inside `displayFrame`.
    var rect: CGRect

    /// The region in the display's own points.
    var localRect: CGRect {
        rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }

    var pixelSize: ScreenPixelSize {
        ScreenPixelSize(width: max(1, Int((rect.width * scale).rounded())),
                        height: max(1, Int((rect.height * scale).rounded())))
    }
}

/// Live frames of the region, leaving Typeflux's own windows out.
protocol ScrollFrameSource: AnyObject {
    /// Starts delivering images as they change, on any queue, as soon as they arrive; `onError`
    /// reports that the stream stopped.
    func start(_ region: ScrollCaptureRegion, onFrame: @escaping @Sendable (CGImage) -> Void,
               onError: @escaping @Sendable (Error) -> Void) async throws
    func stop()
}

/// `SCStream` with `sourceRect` set to the region, at about 15 frames a second. The same path
/// works on macOS 13 and later.
final class ScreenCaptureStreamFrameSource: NSObject, ScrollFrameSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    static let framesPerSecond: Int32 = 15

    private let queue = DispatchQueue(label: "Typeflux.ScrollCapture.frames", qos: .userInitiated)
    private let ownProcessID: pid_t
    private let lock = NSLock()
    private var stream: SCStream?
    private var onFrame: (@Sendable (CGImage) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    init(ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownProcessID = ownProcessID
    }

    func start(_ region: ScrollCaptureRegion, onFrame: @escaping @Sendable (CGImage) -> Void,
               onError: @escaping @Sendable (Error) -> Void) async throws {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ScreenCaptureError.unavailable
        }
        let own = content.applications.filter { $0.processID == ownProcessID }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: region), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock {
            self.stream = stream
            self.onFrame = onFrame
            self.onError = onError
        }
        try await stream.startCapture()
        // Cancellation can happen while the native start operation is in flight.
        if Task.isCancelled {
            stop()
        }
    }

    func stop() {
        let stream = lock.withLock {
            defer {
                self.stream = nil
                onFrame = nil
                onError = nil
            }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    static func configuration(for region: ScrollCaptureRegion) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = region.pixelSize
        config.sourceRect = region.localRect
        config.width = size.width
        config.height = size.height
        config.scalesToFit = false
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        config.queueDepth = 4
        return config
    }

    // MARK: SCStreamOutput

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(sampleBuffer),
              let buffer = sampleBuffer.imageBuffer,
              let image = Self.copyImage(of: buffer) else { return }
        let handler = lock.withLock { onFrame }
        handler?(image)
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        let handler = lock.withLock { onError }
        handler?(error)
    }

    /// Frames that carry new pixels; idle and blank frames have none.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// A copy of the pixels, so the stream's buffer goes back to its pool at once.
    static func copyImage(of buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let source = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow, space: space, bitmapInfo: info),
            let view = source.makeImage() else { return nil }
        // That image may still share the buffer, which the stream reuses: draw it into memory of our own.
        guard let copy = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        copy.draw(view, in: CGRect(x: 0, y: 0, width: width, height: height))
        return copy.makeImage()
    }
}
