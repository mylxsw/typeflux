import AVFoundation
import CoreImage
import Foundation

/// Serializes the media timeline, camera composite and writer. The admission gate
/// bounds retained native buffers even when an encoder falls behind.
final class ScreenRecordingWriter: @unchecked Sendable {
    enum Track: Hashable { case screen, systemAudio, microphone, camera }
    let queue = DispatchQueue(label: "Typeflux.Recording.writer", qos: .userInitiated)
    private let gate = NSLock()
    private var pending = 0
    private let assetWriter: AVAssetWriter
    private let video: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let audio: [Track: AVAssetWriterInput]
    private let options: ScreenRecordingOptions
    private let size: CGSize
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timeline = ScreenRecordingTimeline()
    private var lastPixel: CVPixelBuffer?
    private var lastScreen: CVPixelBuffer?
    private var camera: CVPixelBuffer?
    private var cameraTime: Double = 0
    private var lastVideoTime: Double = -1
    private var lastAudioTime: [Track: Double] = [:]
    private var terminal = false
    private var failure: Error?
    var onFailure: (@Sendable (Error) -> Void)?

    init(url: URL, size: CGSize, options: ScreenRecordingOptions) throws {
        self.options = options
        self.size = size
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 5),
                AVVideoExpectedSourceFrameRateKey: options.captureFPS,
                AVVideoMaxKeyFrameIntervalKey: options.captureFPS * 2
            ],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        video.expectsMediaDataInRealTime = true
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard assetWriter.canAdd(video) else { throw ScreenRecordingFailure.encoding }
        assetWriter.add(video)
        var inputs: [Track: AVAssetWriterInput] = [:]
        for (track, enabled) in [(Track.systemAudio, options.systemAudio), (.microphone, options.microphone)]
            where enabled && options.capturesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else { throw ScreenRecordingFailure.encoding }
            assetWriter.add(input)
            inputs[track] = input
        }
        audio = inputs
        guard assetWriter.startWriting() else { throw assetWriter.error ?? ScreenRecordingFailure.encoding }
    }

    func offer(_ sample: CMSampleBuffer, track: Track, hostTime: Double) {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return }
        let admitted = gate.withLock { () -> Bool in
            guard pending < 8 else { return false }
            pending += 1
            return true
        }
        guard admitted else { return }
        queue.async { [self] in
            defer { gate.withLock { pending -= 1 } }
            guard !terminal, failure == nil else { return }
            do { try append(sample, track: track, hostTime: hostTime) } catch { fail(error) }
        }
    }

    private func append(_ sample: CMSampleBuffer, track: Track, hostTime: Double) throws {
        if track == .camera {
            camera = sample.imageBuffer
            cameraTime = hostTime
            // ScreenCaptureKit can remain idle while only the camera moves.
            if let lastScreen, let seconds = timeline.sampleTime(at: hostTime),
               seconds - lastVideoTime >= 1 / Double(options.captureFPS),
               options.durationLimit.map({ seconds <= $0 }) ?? true {
                try appendVideo(lastScreen, seconds: seconds, hostTime: hostTime)
            }
            return
        }
        if timeline.origin == nil, track == .screen {
            timeline.start(at: hostTime)
            assetWriter.startSession(atSourceTime: .zero)
        }
        guard let seconds = timeline.sampleTime(at: hostTime),
              options.durationLimit.map({ seconds <= $0 }) ?? true else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        if track == .screen {
            guard let image = sample.imageBuffer else { return }
            lastScreen = image
            try appendVideo(image, seconds: seconds, hostTime: hostTime)
        } else if let input = audio[track], input.isReadyForMoreMediaData,
                  seconds > (lastAudioTime[track] ?? -1) {
            let retimed = try Self.retimed(sample, to: time)
            guard input.append(retimed) else { throw assetWriter.error ?? ScreenRecordingFailure.encoding }
            lastAudioTime[track] = seconds
        }
    }

    private func appendVideo(_ image: CVPixelBuffer, seconds: Double, hostTime: Double) throws {
        guard seconds > lastVideoTime, video.isReadyForMoreMediaData else { return }
        let buffer = try composite(image, at: hostTime)
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        guard pixels.append(buffer, withPresentationTime: time) else {
            throw assetWriter.error ?? ScreenRecordingFailure.encoding
        }
        lastPixel = buffer
        lastVideoTime = seconds
    }

    private func composite(_ screen: CVPixelBuffer, at time: Double) throws -> CVPixelBuffer {
        guard options.camera, let camera, abs(time - cameraTime) < 1 else { return screen }
        guard let pool = pixels.pixelBufferPool else { throw ScreenRecordingFailure.encoding }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            throw ScreenRecordingFailure.encoding
        }
        let rect = ScreenRecordingGeometry.cameraRect(in: size, fraction: options.cameraFraction,
                                                      corner: options.cameraCorner)
        let image = CIImage(cvPixelBuffer: camera)
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: (scaled.extent.width - rect.width) / 2,
                          y: (scaled.extent.height - rect.height) / 2, width: rect.width, height: rect.height)
        let inset = scaled.cropped(to: crop).transformed(by: CGAffineTransform(
            translationX: rect.minX - crop.minX, y: rect.minY - crop.minY
        ))
        context.render(inset.composited(over: CIImage(cvPixelBuffer: screen)), to: output,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return output
    }

    static func retimed(_ sample: CMSampleBuffer, to time: CMTime) throws -> CMSampleBuffer {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing,
                                                            entriesNeededOut: nil)
        guard status == noErr, count > 0 else { throw ScreenRecordingFailure.encoding }
        let offset = sample.presentationTimeStamp - time
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp
                .isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset)
            }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &result
        ) == noErr,
            let result else { throw ScreenRecordingFailure.encoding }
        return result
    }

    func setPaused(_ paused: Bool, at time: Double) {
        queue.async { [self] in
            if paused {
                timeline.pause(at: time)
            } else {
                timeline.resume(at: time)
            }
        }
    }

    func elapsed(at time: Double) async -> Double {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: timeline.position(at: time) ?? 0) }
        }
    }

    func finish(at time: Double) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !terminal else { continuation.resume(throwing: CancellationError()); return }
                terminal = true
                if let failure {
                    assetWriter.cancelWriting()
                    continuation.resume(throwing: failure)
                    return
                }
                guard let lastPixel, lastVideoTime >= 0 else {
                    assetWriter.cancelWriting()
                    continuation.resume(throwing: ScreenRecordingFailure.noFrames)
                    return
                }
                let duration = min(options.durationLimit ?? .greatestFiniteMagnitude,
                                   max(
                                       lastVideoTime + 1 / Double(options.captureFPS),
                                       timeline.position(at: time) ?? 0
                                   ))
                let tail = duration - 1 / Double(options.captureFPS)
                if tail > lastVideoTime, video.isReadyForMoreMediaData {
                    _ = pixels.append(lastPixel, withPresentationTime: CMTime(seconds: tail, preferredTimescale: 60000))
                }
                assetWriter.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
                video.markAsFinished()
                audio.values.forEach { $0.markAsFinished() }
                self.lastPixel = nil
                lastScreen = nil
                camera = nil
                assetWriter.finishWriting { [self] in
                    if assetWriter.status == .completed {
                        continuation.resume(returning: assetWriter.outputURL)
                    } else {
                        continuation.resume(throwing: assetWriter.error ?? ScreenRecordingFailure.encoding)
                    }
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                terminal = true
                if assetWriter.status == .writing {
                    assetWriter.cancelWriting()
                }
                lastPixel = nil
                lastScreen = nil
                camera = nil
                continuation.resume()
            }
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure?(error)
    }
}
