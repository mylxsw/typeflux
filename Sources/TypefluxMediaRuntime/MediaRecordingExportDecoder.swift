import AVFoundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import TypefluxMediaProtocol

/// Native encoding lives only in the disposable media executable. Failed files stay owned.
public enum MediaRecordingExportDecoder {
    public static func run() async {
        do {
            let bytes = FileHandle.standardInput.readData(ofLength: 1025)
            guard bytes.count <= 1024 else { throw MediaFailure.invalidProtocol }
            let request = try JSONDecoder().decode(MediaRecordingExport.self, from: bytes)
            try request.validate()
            let writer = Writer(request.id)
            do {
                // A hard per-file ceiling also covers ImageIO and native writes between progress ticks.
                var limit = rlimit(rlim_cur: rlim_t(request.outputLimit), rlim_max: rlim_t(request.outputLimit))
                guard setrlimit(RLIMIT_FSIZE, &limit) == 0 else { throw MediaFailure.unavailable }
                signal(SIGXFSZ, SIG_IGN)
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let count = try await encode(request, directory: directory) { writer.update($0) }
                writer.finish(bytes: count)
            } catch { writer.finish(bytes: nil) }
        } catch { /* Invalid requests receive no acknowledgement. */ }
    }

    public static func encode(_ request: MediaRecordingExport, directory: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        try request.validate()
        let source = directory.appendingPathComponent("input.mov")
        let destination = directory.appendingPathComponent(request.outputName)
        _ = try fileSize(source, limit: MediaRecordingExport.inputBytes)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MediaFailure.invalidProtocol }
        let asset = AVURLAsset(url: source, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 86400, request.end <= duration + 0.01,
              request.start < duration else { throw MediaFailure.unreadable }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count <= 8 else { throw MediaFailure.tooLarge }
        let size = try await videos[0].load(.naturalSize)
        try MediaRecordingPosterDecoder.size(size.width, size.height)
        let transform = try await videos[0].load(.preferredTransform)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy({ $0.isFinite }) else { throw MediaFailure.unreadable }
        let transformed = CGRect(origin: .zero, size: size).applying(transform).size
        try MediaRecordingPosterDecoder.size(transformed.width, transformed.height)
        guard abs(transform.tx) <= 16384, abs(transform.ty) <= 16384 else { throw MediaFailure.tooLarge }
        for audio in audios {
            let descriptions = try await audio.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.count <= 8 else { throw MediaFailure.tooLarge }
            for description in descriptions {
                guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mSampleRate.isFinite, format.mSampleRate > 0, format.mSampleRate <= 384000,
                      format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 64 else { throw MediaFailure.tooLarge }
            }
        }
        let fps = Double(try await videos[0].load(.nominalFrameRate))
        let seconds = min(request.end, duration) - request.start
        guard fps.isFinite, fps >= 0, fps <= 240, seconds * (fps == 0 ? 240 : fps) <= 10_000_000 else { throw MediaFailure.tooLarge }
        let range = CMTimeRange(start: CMTime(seconds: request.start, preferredTimescale: 600), duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try Task.checkCancellation()
        switch request.format {
        case .mp4: try await video(asset, to: destination, range: range, request: request, progress: progress)
        case .gif: try gif(asset: asset, destination: destination, range: range, rate: request.rate, progress: progress)
        }
        let bytes = try fileSize(destination, limit: request.outputLimit)
        // A native file-length limit can finish early. Never publish a truncated trim as success.
        if request.format == .mp4 {
            let output = AVURLAsset(url: destination, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            let actual = try await output.load(.duration).seconds
            guard actual.isFinite, abs(actual - seconds / request.rate) <= 0.05,
                  try await output.loadTracks(withMediaType: .video).count == 1 else { throw MediaFailure.unreadable }
        } else {
            guard let image = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  CGImageSourceGetType(image) as String? == UTType.gif.identifier,
                  CGImageSourceGetCount(image) == max(1, Int(ceil(seconds / request.rate * 10))),
                  CGImageSourceGetStatus(image) == .statusComplete else { throw MediaFailure.unreadable }
        }
        return bytes
    }
    private static func fileSize(_ url: URL, limit: Int) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= limit else { throw MediaFailure.tooLarge }
        return Int(info.st_size)
    }

    private final class Writer: @unchecked Sendable {
        let id: UUID
        let lock = NSLock()
        var sequence = 0, last = 0.0, time = -Double.infinity
        init(_ id: UUID) { self.id = id }
        func update(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            guard value.isFinite, value >= last, value <= 1, now - time >= 1, sequence < 602 else { return }
            last = value; time = now
            emit(.progress, bytes: nil)
        }
        func finish(bytes: Int?) {
            lock.lock(); defer { lock.unlock() }
            if bytes != nil { last = 1 }
            emit(bytes == nil ? .failed : .completed, bytes: bytes)
        }
        private func emit(_ kind: MediaRecordingExportEvent.Kind, bytes: Int?) {
            sequence += 1
            let event = MediaRecordingExportEvent(id: id, sequence: sequence, kind: kind, progress: last, bytes: bytes)
            if var data = try? JSONEncoder().encode(event), data.count <= 1024 {
                data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
            }
        }
    }
    private static func video(_ asset: AVAsset, to destination: URL, range: CMTimeRange, request: MediaRecordingExport,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        // Composition combines the kept microphone and system tracks into one portable AAC track.
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first,
              let video = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw MediaFailure.unreadable }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let parameters = try await audio(asset: asset, into: composition, range: range, volumes: request.volumes)
        if request.rate != 1 {
            let scaled = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / request.rate)
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: scaled)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw MediaFailure.unavailable
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        session.audioMix = mix
        // Keeps voices at their natural pitch when the recording is sped up or slowed down.
        session.audioTimePitchAlgorithm = .spectral
        session.outputFileType = .mp4
        session.outputURL = destination
        session.shouldOptimizeForNetworkUse = true
        session.fileLengthLimit = Int64(MediaRecordingExport.inputBytes)
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .seconds(1))
            }
        }

        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        monitor.cancel()
        await monitor.value
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? MediaFailure.unavailable }
        progress(1)
    }

    /// Adds the kept source audio tracks to `composition`. A zero volume leaves the track out entirely.
    private static func audio(asset: AVAsset, into composition: AVMutableComposition, range: CMTimeRange,
                              volumes: [Double]?) async throws -> [AVAudioMixInputParameters] {
        let sources = try await asset.loadTracks(withMediaType: .audio)
        // Volumes are addressed by source track position, so a list for a different track count is refused.
        guard volumes.map({ $0.count == sources.count }) ?? true else { throw MediaFailure.invalidProtocol }
        let levels = volumes ?? Array(repeating: 1, count: sources.count)
        let kept = sources.indices.filter { levels[$0] > 0 }
        var parameters: [AVAudioMixInputParameters] = []
        for index in kept {
            let overlap = try await CMTimeRangeGetIntersection(range, otherRange: sources[index].load(.timeRange))
            guard overlap.duration.seconds > 0 else { continue }
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw MediaFailure.unavailable }
            try track.insertTimeRange(overlap, of: sources[index], at: overlap.start - range.start)
            let parameter = AVMutableAudioMixInputParameters(track: track)
            // Two full-scale tracks would clip once mixed into a single track.
            parameter.setVolume(Float(levels[index] * (kept.count > 1 ? 0.5 : 1)), at: .zero)
            parameters.append(parameter)
        }
        return parameters
    }

    public static func frameCount(_ duration: Double) throws -> Int {
        guard duration.isFinite, duration > 0, duration <= 30.01 else { throw MediaFailure.tooLarge }
        return max(1, Int(ceil(duration * 10)))
    }
    private static func gif(asset: AVAsset, destination: URL, range: CMTimeRange, rate: Double,
                            progress: @escaping @Sendable (Double) -> Void) throws {
        // GIF timing is in output seconds; each frame samples the source `rate` times further along.
        let duration = range.duration.seconds / rate
        let frames = try frameCount(duration)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                           frames, nil) else { throw MediaFailure.unavailable }
        CGImageDestinationSetProperties(
            output,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        let reader = AVAssetImageGenerator(asset: asset)
        reader.appliesPreferredTrackTransform = true
        reader.maximumSize = CGSize(width: 960, height: 960)
        reader.requestedTimeToleranceBefore = .zero
        reader.requestedTimeToleranceAfter = .zero
        defer { reader.cancelAllCGImageGeneration() }
        for index in 0 ..< frames {
            try Task.checkCancellation()
            try autoreleasepool {
                let position = Double(index) / 10
                let offset = min(position * rate, range.duration.seconds)
                let time = range.start + CMTime(seconds: offset, preferredTimescale: 600)
                let image = try reader.copyCGImage(at: time, actualTime: nil)
                guard image.width <= 960, image.height <= 960 else { throw MediaFailure.tooLarge }
                let delay = max(0.02, min(0.1, duration - position))
                CGImageDestinationAddImage(output, image, [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay
                ]] as CFDictionary)
            }
            progress(Double(index + 1) / Double(frames + 1))
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(output) else { throw MediaFailure.unavailable }
        progress(1)
    }
}
