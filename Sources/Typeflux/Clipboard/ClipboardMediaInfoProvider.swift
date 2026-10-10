import AVFoundation
import PDFKit

/// Facts about a copied file that need decoding: playback length, PDF page count.
struct ClipboardMediaInfo: Equatable {
    var duration: TimeInterval?
    var pageCount: Int?
}

/// Loads and caches media facts and audio waveforms for clipboard rows, off the main thread.
final class ClipboardMediaInfoProvider {
    static let shared = ClipboardMediaInfoProvider()

    /// Long recordings only sample their beginning, so a waveform never decodes hours of audio.
    static let waveformScanLimit: TimeInterval = 600
    /// Peaks need no fidelity, so decode at the lowest rate AVAssetReader accepts (8 kHz; lower
    /// raises an Objective-C exception). A 10-minute scan streams under 5 million samples.
    private static let waveformSampleRate: Double = 8000
    /// Each file is decoded once at this resolution; rows resample it to the bars they draw.
    static let waveformResolution = 180

    private final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private let infoCache = NSCache<NSString, Box<ClipboardMediaInfo>>()
    private let waveformCache = NSCache<NSString, Box<[Float]>>()

    init() {
        infoCache.countLimit = 300
        waveformCache.countLimit = 100
    }

    func cachedInfo(for url: URL) -> ClipboardMediaInfo? {
        infoCache.object(forKey: url.path as NSString)?.value
    }

    /// Duration for video and audio, page count for PDFs; `nil` for other kinds or unreadable files.
    func info(for url: URL, kind: ClipboardEntryKind) async -> ClipboardMediaInfo? {
        if let cached = cachedInfo(for: url) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info: ClipboardMediaInfo
        switch kind {
        case .video, .audio:
            guard let duration = await Self.duration(of: url) else { return nil }
            info = ClipboardMediaInfo(duration: duration)
        case .pdf:
            guard let pages = await Task.detached(priority: .utility, operation: { PDFDocument(url: url)?.pageCount })
                .value
            else { return nil }
            info = ClipboardMediaInfo(pageCount: pages)
        default:
            return nil
        }
        infoCache.setObject(Box(info), forKey: url.path as NSString)
        return info
    }

    /// The info a row or the preview pane shows for an entry: its first file's duration or page count.
    func loadInfo(for entry: ClipboardEntry) async -> ClipboardMediaInfo? {
        guard [.video, .audio, .pdf].contains(entry.kind), let url = entry.fileURLs.first else { return nil }
        return await info(for: url, kind: entry.kind)
    }

    func cachedWaveform(for url: URL, bars: Int) -> [Float]? {
        guard bars > 0, let levels = waveformCache.object(forKey: url.path as NSString)?.value else { return nil }
        return Self.resample(levels, to: bars)
    }

    /// `bars` peak levels in `0...1` covering the recording (or its first `waveformScanLimit` seconds).
    /// Cancelling the calling task stops the decode.
    func waveform(for url: URL, bars: Int) async -> [Float]? {
        if let cached = cachedWaveform(for: url, bars: bars) { return cached }
        guard bars > 0, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let levels = await Self.readWaveform(of: url, bars: Self.waveformResolution) else { return nil }
        waveformCache.setObject(Box(levels), forKey: url.path as NSString)
        return Self.resample(levels, to: bars)
    }

    /// Max-pools (or stretches) `levels` to `bars` values, so peaks survive downsampling.
    static func resample(_ levels: [Float], to bars: Int) -> [Float] {
        guard bars > 0, !levels.isEmpty else { return [] }
        if levels.count == bars { return levels }
        return (0 ..< bars).map { index in
            let start = index * levels.count / bars
            let end = max((index + 1) * levels.count / bars, start + 1)
            return levels[start ..< min(end, levels.count)].max() ?? 0
        }
    }

    private static func duration(of url: URL) async -> TimeInterval? {
        guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func readWaveform(of url: URL, bars: Int) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let total = await duration(of: url)
        else { return nil }
        // The decode runs detached so it never blocks a row; the flag carries cancellation across.
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                decodePeaks(
                    asset: asset, track: track, seconds: min(total, waveformScanLimit), bars: bars,
                    isCancelled: cancellation.isSet
                )
            }.value
        } onCancel: {
            cancellation.set()
        }
    }

    private final class CancellationFlag {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func isSet() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func decodePeaks(
        asset: AVAsset, track: AVAssetTrack, seconds: TimeInterval, bars: Int, isCancelled: () -> Bool
    ) -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: waveformSampleRate
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var accumulator = ClipboardWaveformAccumulator(
            bars: bars, expectedSamples: Int(seconds * waveformSampleRate)
        )
        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }
            accumulator.add(samples)
        }
        guard reader.status == .completed else { return nil }
        return accumulator.levels()
    }
}

/// Folds a stream of PCM samples into a fixed number of peak bars.
struct ClipboardWaveformAccumulator {
    private(set) var peaks: [Float]
    private let expectedSamples: Int
    private var count = 0

    init(bars: Int, expectedSamples: Int) {
        peaks = Array(repeating: 0, count: max(bars, 1))
        self.expectedSamples = max(expectedSamples, 1)
    }

    mutating func add(_ samples: [Float]) {
        let bars = peaks.count
        for sample in samples {
            // Decoders may deliver a little more than the estimate; the overflow lands in the last bar.
            let index = min(count * bars / expectedSamples, bars - 1)
            peaks[index] = max(peaks[index], abs(sample))
            count += 1
        }
    }

    /// Peaks scaled so the loudest bar is 1. Silence stays all zeros.
    func levels() -> [Float] {
        guard let loudest = peaks.max(), loudest > 0 else { return peaks }
        return peaks.map { min($0 / loudest, 1) }
    }
}
