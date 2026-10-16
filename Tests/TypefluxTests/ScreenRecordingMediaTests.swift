import AVFoundation
import ImageIO
import Testing
@testable import Typeflux

/// Real codecs with synthetic media: no screen, microphone or camera permission required.
@Suite("Screen recording media")
struct ScreenRecordingMediaTests {
    static func videoSample(at seconds: Double, width: Int = 160, height: Int = 120,
                            gray: UInt8 = 128) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) ==
                kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(gray), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                             formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(try CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixels,
            formatDescription: #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr)
        return try #require(sample)
    }

    static func audioSample(at seconds: Double, frequency: Double = 440, rate: Double = 48000,
                            channels: Int = 2) throws -> CMSampleBuffer {
        let frames = Int(rate / 10)
        let stride = channels * 4
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                      mBytesPerPacket: UInt32(stride), mFramesPerPacket: 1,
                                                      mBytesPerFrame: UInt32(stride),
                                                      mChannelsPerFrame: UInt32(channels),
                                                      mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * stride,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: frames * stride,
                                                   flags: 0, blockBufferOut: &block) == noErr)
        let bytes = try #require(block)
        var data = [Float](repeating: 0, count: frames * channels)
        for frame in 0 ..< frames {
            let value = Float(sin(Double(frame) / rate * frequency * 2 * .pi) * 0.2)
            for channel in 0 ..< channels {
                data[frame * channels + channel] = value
            }
        }
        #expect(CMBlockBufferReplaceDataBytes(with: &data, blockBuffer: bytes, offsetIntoDestination: 0,
                                              dataLength: frames * stride) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(try CMSampleBufferCreateReady(allocator: nil, dataBuffer: bytes, formatDescription: #require(format),
                                              sampleCount: frames, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing,
                                              sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                              sampleBufferOut: &sample) ==
                noErr)
        return try #require(sample)
    }

    static func makeMovie(at url: URL, withAudio: Bool = false, withCamera: Bool = false) async throws {
        var options = ScreenRecordingOptions()
        options.systemAudio = withAudio
        options.microphone = withAudio
        options.camera = withCamera
        let writer = try ScreenRecordingWriter(url: url, size: CGSize(width: 160, height: 120), options: options)
        for frame in 0 ..< 12 {
            let time = 100 + Double(frame) / 10
            if withCamera {
                try writer.offer(
                    videoSample(at: time, width: 80, height: 60, gray: 240),
                    track: .camera,
                    hostTime: time
                )
            }
            try writer.offer(videoSample(at: time, gray: UInt8(frame * 15)), track: .screen, hostTime: time)
            if withAudio {
                try writer.offer(audioSample(at: time), track: .systemAudio, hostTime: time)
                try writer.offer(
                    audioSample(at: time, frequency: 880, rate: 44100, channels: 1),
                    track: .microphone,
                    hostTime: time
                )
            }
            _ = await writer.elapsed(at: time)
            // Give the asynchronous hardware encoder time to become ready.
            try await Task.sleep(for: .milliseconds(15))
        }
        _ = try await writer.finish(at: 101.2)
    }

    @Test func `empty and cancelled recordings cannot produce A valid movie`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try ScreenRecordingWriter(url: directory.appendingPathComponent("empty.mov"),
                                               size: CGSize(width: 160, height: 120), options: ScreenRecordingOptions())
        await #expect(throws: ScreenRecordingFailure.noFrames) { try await writer.finish(at: 1) }
        await #expect(throws: CancellationError.self) { try await writer.finish(at: 2) }
        let cancelled = try ScreenRecordingWriter(url: directory.appendingPathComponent("cancelled.mov"),
                                                  size: CGSize(width: 160, height: 120),
                                                  options: ScreenRecordingOptions())
        await cancelled.cancel()
        try cancelled.offer(Self.videoSample(at: 1), track: .screen, hostTime: 1)
        await #expect(throws: CancellationError.self) { try await cancelled.finish(at: 2) }
    }

    @Test func `paused movie keeps static tail and removes pause duration`() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ScreenRecordingWriter(
            url: url,
            size: CGSize(width: 160, height: 120),
            options: ScreenRecordingOptions()
        )
        try writer.offer(Self.videoSample(at: 100), track: .screen, hostTime: 100)
        #expect(await writer.elapsed(at: 102) == 2)
        writer.setPaused(true, at: 102)
        try writer.offer(Self.videoSample(at: 103), track: .screen, hostTime: 103)
        writer.setPaused(false, at: 105)
        #expect(await writer.elapsed(at: 106) == 3)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await writer.finish(at: 108)
        let asset = AVURLAsset(url: url)
        #expect(try await abs(asset.load(.duration).seconds - 5) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try generator.copyCGImage(at: CMTime(seconds: 4.8, preferredTimescale: 600), actualTime: nil)
        #expect(image.width == 160 && image.height == 120)
    }

    @Test func `real MP 4 mixes both audio tracks and GIF honors trim`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await Self.makeMovie(at: source, withAudio: true, withCamera: true)
        let sourceAsset = AVURLAsset(url: source)
        #expect(try await sourceAsset.loadTracks(withMediaType: .audio).count == 2)
        let exporter = ScreenRecordingExporter(encoder: ScreenRecordingEncoder(worker: MediaWorker(timeout: 600)))
        let mp4 = directory.appendingPathComponent("result.mp4")
        let trim = ScreenRecordingTrim(start: 0.2, end: 1)
        try await exporter.export(source: source, destination: mp4, format: .mp4, trim: trim) { _ in }
        let asset = AVURLAsset(url: mp4)
        #expect(try await abs(asset.load(.duration).seconds - 0.8) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 160, height: 120))
        let gif = directory.appendingPathComponent("result.gif")
        try await exporter.export(source: source, destination: gif, format: .gif, trim: trim) { _ in }
        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == 8)
        let properties = try #require(CGImageSourceCopyProperties(image, nil) as? [String: Any])
        let gifProperties = try #require(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        #expect(gifProperties[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
        for index in 0 ..< CGImageSourceGetCount(image) {
            let frame = try #require(CGImageSourceCreateImageAtIndex(image, index, nil))
            #expect(frame.width == 160 && frame.height == 120)
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [String: Any])
            let delay =
                (props[kCGImagePropertyGIFDictionary as String] as? [
                    String: Any
                ])?[kCGImagePropertyGIFDelayTime as String] as? Double
            #expect(delay == 0.1)
        }
    }

    @Test func `retiming preserves audio duration`() throws {
        let sample = try Self.audioSample(at: 100)
        let retimed = try ScreenRecordingWriter.retimed(sample, to: CMTime(seconds: 2.5, preferredTimescale: 600))
        #expect(retimed.presentationTimeStamp.seconds == 2.5)
        #expect(retimed.duration == sample.duration)
        #expect(CMSampleBufferGetNumSamples(retimed) == 4800)
    }
}

extension ScreenRecordingMediaTests {
    @Test func `finishing waits for encoder backpressure before preserving static tail`() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ScreenRecordingOptions()
        options.systemAudio = true
        let writer = try ScreenRecordingWriter(url: url, size: CGSize(width: 760, height: 420), options: options)
        for index in 0 ..< 12 {
            let time = 100 + Double(index) * 3
            try writer.offer(Self.videoSample(at: time, width: 760, height: 420), track: .screen, hostTime: time)
            try writer.offer(Self.audioSample(at: time), track: .systemAudio, hostTime: time)
            _ = await writer.elapsed(at: time)
        }
        _ = try await writer.finish(at: 138.6)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 38.6) < 0.05)
    }
}
