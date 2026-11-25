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

/// Live frames of the region, leaving capture controls out while keeping app pages.
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
    private let captureControlWindowIDs: @MainActor () -> [CGWindowID]
    private let lock = NSLock()
    private var stream: SCStream?
    private var onFrame: (@Sendable (CGImage) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var lastFrame: PixelFrame?

    init(ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
         captureControlWindowIDs: @escaping @MainActor () -> [CGWindowID] = ScreenshotCaptureWindowPolicy.excludedWindowIDs) {
        self.ownProcessID = ownProcessID
        self.captureControlWindowIDs = captureControlWindowIDs
    }

    func start(_ region: ScrollCaptureRegion, onFrame: @escaping @Sendable (CGImage) -> Void,
               onError: @escaping @Sendable (Error) -> Void) async throws {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ScreenCaptureError.unavailable
        }
        let controls = Set(await captureControlWindowIDs())
        try Task.checkCancellation()
        let excluded = content.windows.filter {
            $0.owningApplication?.processID == ownProcessID && controls.contains($0.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: region), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock {
            self.stream = stream
            self.onFrame = onFrame
            self.onError = onError
            lastFrame = nil
        }
        do {
            try Task.checkCancellation()
            try await stream.startCapture()
        } catch {
            _ = detach(stream)
            throw error
        }
        // stop() can detach the stream before its native start has finished.
        if Task.isCancelled || lock.withLock({ self.stream !== stream }) {
            _ = detach(stream)
            try? await stream.stopCapture()
        }
    }

    func stop() {
        detach()?.stopCapture { _ in }
    }

    private func detach(_ expected: SCStream? = nil) -> SCStream? {
        lock.withLock {
            if let expected, stream !== expected { return nil }
            defer {
                stream = nil
                onFrame = nil
                onError = nil
                lastFrame = nil
            }
            return stream
        }
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.carriesPixels(sampleBuffer), let buffer = sampleBuffer.imageBuffer,
              let current = lock.withLock({ self.stream === stream ? (lastFrame, onFrame) : nil }),
              let frame = PixelFrame.copy(of: buffer, differentFrom: current.0),
              let image = frame.makeImage() else { return }
        let handler: (@Sendable (CGImage) -> Void)? = lock.withLock {
            guard self.stream === stream else { return nil }
            lastFrame = frame
            return current.1
        }
        handler?(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = lock.withLock { self.stream === stream ? onError : nil }
        handler?(error)
    }

    /// Frames that carry new pixels; idle and blank frames have none.
    private static func carriesPixels(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete || status == .started
    }

    /// A copy of the pixels, so the stream's buffer goes back to its pool at once.
    static func copyImage(of buffer: CVPixelBuffer) -> CGImage? {
        PixelFrame.copy(of: buffer)?.makeImage()
    }

    struct PixelFrame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: CFData

        /// Complete frames can contain identical pixels when only an excluded window changes.
        /// Compare visible pixels before copying so those updates never reset the settling timer.
        static func copy(of buffer: CVPixelBuffer, differentFrom previous: PixelFrame? = nil) -> PixelFrame? {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            if let previous, previous.width == width, previous.height == height,
               let old = CFDataGetBytePtr(previous.data),
               (0 ..< height).allSatisfy({
                   memcmp(base + $0 * stride, old + $0 * previous.bytesPerRow, width * 4) == 0
               }) {
                return nil
            }
            guard let data = CFDataCreate(nil, base, stride * height) else { return nil }
            return PixelFrame(width: width, height: height, bytesPerRow: stride, data: data)
        }

        func makeImage() -> CGImage? {
            guard let provider = CGDataProvider(data: data) else { return nil }
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}
