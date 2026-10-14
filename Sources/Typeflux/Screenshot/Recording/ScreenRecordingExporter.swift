import AVFoundation
import ImageIO
import UniformTypeIdentifiers

protocol ScreenRecordingExporting {
    func export(source: URL, destination: URL, format: ScreenRecordingFormat, trim: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws
}

struct ScreenRecordingExporter: ScreenRecordingExporting {
    func export(source: URL, destination: URL, format: ScreenRecordingFormat, trim: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let range = try trim.validated(duration: duration, format: format)
        try Task.checkCancellation()
        do {
            switch format {
            case .mp4:
                try await video(asset: asset, destination: destination, range: range, progress: progress)
            case .gif:
                let job = Task.detached(priority: .userInitiated) {
                    try gif(asset: asset, destination: destination, range: range, progress: progress)
                }
                try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func video(asset: AVAsset, destination: URL, range: CMTimeRange,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        // Composition combines the microphone and system tracks into one portable AAC track.
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first,
              let video = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw ScreenRecordingFailure.noFrames }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let audioSources = try await asset.loadTracks(withMediaType: .audio)
        var parameters: [AVAudioMixInputParameters] = []
        for source in audioSources {
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            else { throw ScreenRecordingFailure.encoding }
            let overlap = try await CMTimeRangeGetIntersection(range, otherRange: source.load(.timeRange))
            guard overlap.duration.seconds > 0 else { continue }
            try track.insertTimeRange(overlap, of: source, at: overlap.start - range.start)
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(audioSources.count > 1 ? 0.5 : 1, at: .zero)
            parameters.append(parameter)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw ScreenRecordingFailure.encoding
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        session.audioMix = mix
        session.outputFileType = .mp4
        session.outputURL = destination
        session.shouldOptimizeForNetworkUse = true
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { monitor.cancel() }
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? ScreenRecordingFailure.encoding }
        progress(1)
    }

    private func gif(asset: AVAsset, destination: URL, range: CMTimeRange,
                     progress: @escaping @Sendable (Double) -> Void) throws {
        let duration = range.duration.seconds
        let frames = max(1, Int(ceil(duration * 10)))
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                           frames, nil) else { throw ScreenRecordingFailure.encoding }
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
                let time = range.start + CMTime(seconds: position, preferredTimescale: 600)
                let image = try reader.copyCGImage(at: time, actualTime: nil)
                let delay = max(0.02, min(0.1, duration - position))
                CGImageDestinationAddImage(output, image, [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay
                ]] as CFDictionary)
            }
            progress(Double(index + 1) / Double(frames + 1))
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(output) else { throw ScreenRecordingFailure.encoding }
        progress(1)
    }
}

/// Keeps recoverable source files outside the temporary directory. Publishing is
/// a same-directory move and never replaces an existing user file.
struct ScreenRecordingFiles {
    let root: URL
    var manager: FileManager = .default

    static var live: Self {
        Self(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/Recordings", isDirectory: true))
    }

    func createSession(options: ScreenRecordingOptions) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(options).write(to: directory.appendingPathComponent("options.json"), options: .atomic)
        return directory
    }

    func recoverableSources() -> [URL] {
        ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("source.mov") }
            .filter { manager.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
    }

    func discard(_ directory: URL) {
        // Only the directory owned by this feature can be removed.
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent()
            == root.resolvingSymlinksInPath() else { return }
        try? manager.removeItem(at: directory)
    }

    func publish(
        _ source: URL,
        in directory: URL,
        format: ScreenRecordingFormat,
        date: Date = Date(),
        name: String? = nil,
        destinationURL: URL? = nil
    ) throws -> URL {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".typeflux-recording-\(UUID().uuidString).\(format.rawValue)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        if let destinationURL {
            guard destinationURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            else { throw CocoaError(.fileWriteInvalidFileName) }
            if manager.fileExists(atPath: destinationURL.path) {
                _ = try manager.replaceItemAt(destinationURL, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destinationURL)
            }
            return destinationURL
        }
        let base = name.map(ScreenRecordingLayout.fileName) ?? ("Typeflux Recording " + formatter.string(from: date))
        for suffix in 0 ..< 10000 {
            let name = base + (suffix == 0 ? "" : " (\(suffix + 1))") + "." + format.rawValue
            let result = directory.appendingPathComponent(name)
            do { try manager.moveItem(at: staging, to: result); return result } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
