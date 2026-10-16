import AVFoundation
import CoreImage
import TypefluxMediaProtocol

/// AVPlayer's own item clock selects the video frame; audio stays in the same child player.
/// There is one retained frame, replaced only when the host asks for its next snapshot.
@MainActor final class MediaVideoFrames {
    private let output: AVPlayerItemVideoOutput
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let duration: Double
    private var latest: (MediaPlaybackFrame, Data)?
    private var lastRequest: Double?

    init(item: AVPlayerItem, track: AVAssetTrack, duration: Double) async throws {
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 8192, size.height <= 8192, size.width * size.height <= 16_777_216,
              [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite)
        else { throw MediaFailure.tooLarge }
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              bounds.width <= 16384, bounds.height <= 16384 else { throw MediaFailure.tooLarge }
        let scale = min(1, CGFloat(MediaPlaybackFrame.maximumEdge) / max(bounds.width, bounds.height),
                        sqrt(CGFloat(MediaPlaybackFrame.maximumPixels) / (bounds.width * bounds.height)))
        let rendered = CGSize(width: max(1, floor(bounds.width * scale)), height: max(1, floor(bounds.height * scale)))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(.init(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(.init(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]; composition.renderSize = rendered
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        item.videoComposition = composition
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.suppressesPlayerRendering = true
        item.add(output)
        self.duration = duration
    }

    func snapshot(at time: CMTime, refresh: Bool) async throws -> (MediaPlaybackFrame, Data)? {
        if refresh, let lastRequest, abs(lastRequest - time.seconds) < 0.0001, let latest { return latest }
        if refresh { latest = nil }
        defer { if latest != nil { lastRequest = time.seconds } }
        // Loading/seeking may need a short decode wait. Normal playback never queues frames.
        for attempt in 0..<(refresh ? 100 : 1) {
            var actual = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &actual) {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let timestamp = actual.seconds
                // Seeking flushes the output asynchronously. Never present a stale frame
                // from the previous position or an un-timestamped transitional buffer.
                // Acquisition is gated by hasNewPixelBuffer: repeated reads can return an old frame.
                if !timestamp.isFinite || timestamp < 0 || timestamp > duration || (refresh && timestamp > time.seconds + 0.05) {
                    if refresh { try await Task.sleep(for: .milliseconds(10)); continue }
                    return latest
                }
                let frame = MediaPlaybackFrame(width: width, height: height, time: timestamp)
                try frame.validate(duration: duration)
                let image = CIImage(cvPixelBuffer: buffer)
                guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)),
                      let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: frame.stride, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                      let bytes = bitmap.data else { throw MediaFailure.unavailable }
                bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                latest = (frame, Data(bytes: bytes, count: frame.bytes))
                break
            }
            if refresh, attempt < 99 { try await Task.sleep(for: .milliseconds(10)) }
        }
        return latest
    }
}
