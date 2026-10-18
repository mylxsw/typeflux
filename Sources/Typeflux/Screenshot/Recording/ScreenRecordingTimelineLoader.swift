import AppKit
import TypefluxMediaProtocol

/// One admitted batch owns its private source and pixel reservation until real retirement.
final class ScreenRecordingTimelineLoader: @unchecked Sendable {
    static let shared = ScreenRecordingTimelineLoader()
    private static let slots = AskToolPixelBudget(limit: 2)
    private let worker: MediaWorker
    typealias SourceReader = @Sendable (URL, Int) throws -> ClipboardPlaybackSource
    private let readSource: SourceReader
    private let budget: AskToolPixelBudget
    init(worker: MediaWorker = .recordingTimeline, budget: AskToolPixelBudget = .shared,
         readSource: @escaping SourceReader = { try ClipboardPlaybackSource($0, limit: $1) }) {
        self.worker = worker; self.budget = budget; self.readSource = readSource
    }
    func load(_ url: URL) async throws -> ScreenRecordingPreviewMedia {
        try Task.checkCancellation()
        let authorization = worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let ownership = try Ownership(slot: Self.slots.acquire(bytes: 1),
            pixels: budget.acquire(bytes: MediaRecordingTimeline.pixelBytes * 2))
        let cancellation = AskSearchCancellation(), worker = self.worker, readSource = self.readSource
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                if cancelled() { throw CancellationError() }
                let source = try readSource(url, MediaRecordingTimeline.inputBytes)
                if cancelled() { throw CancellationError() }
                let result = try worker.perform(.recordingTimeline, input: .file(url), retaining: ownership, authorization: authorization,
                    isCancelled: cancelled) { response, directory in
                        guard let value = response.timeline else { throw MediaFailure.invalidProtocol }
                        let images = try value.rasters.enumerated().map { index, raster in
                            try Self.image(raster, bytes: MediaPreviewDisplay.read(raster, index: index, directory: directory), lease: ownership.pixels)
                        }
                        return ScreenRecordingPreviewMedia(thumbnails: images, waveform: value.waveform,
                            tracks: value.tracks,
                            size: .init(width: value.width, height: value.height), fps: value.fps,
                            fileBytes: Int64(source.bytes), audio: value.audio)
                    }
                try source.check()
                if cancelled() { throw CancellationError() }
                return result
            }.value
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            return result
        } onCancel: { cancellation.cancel() }
    }
    static func inspect(_ url: URL,
                        readSource: @escaping SourceReader = { try ClipboardPlaybackSource($0, limit: $1) }) async throws -> ClipboardPlaybackSource {
        try Task.checkCancellation()
        let slot = try slots.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached {
                if cancellation.isCancelled { throw CancellationError() }
                return try readSource(url, MediaRecordingTimeline.inputBytes)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
    func thumbnail(_ url: URL) async throws -> CGImage {
        try Task.checkCancellation()
        let gif = url.pathExtension.lowercased() == "gif"
        guard gif || ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else { throw MediaFailure.unreadable }
        let authorization = worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let ownership = try Ownership(slot: Self.slots.acquire(bytes: 1), pixels: budget.acquire(bytes: 200 * 120 * 8))
        let cancellation = AskSearchCancellation(), worker = self.worker, readSource = self.readSource
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                if cancelled() { throw CancellationError() }
                let source = try readSource(url, gif ? MediaLimits.inputBytes : MediaRecordingTimeline.inputBytes)
                if cancelled() { throw CancellationError() }
                let result = try worker.perform(gif ? .recordingPosterGIF : .recordingPosterVideo, input: .file(url),
                    preview: .init(width: 200, height: 120), retaining: ownership, authorization: authorization,
                    isCancelled: cancelled) { response, directory in
                        guard let raster = response.preview?.rasters.first else { throw MediaFailure.invalidProtocol }
                        return try Self.image(raster, bytes: MediaPreviewDisplay.read(raster, index: 0, directory: directory), lease: ownership.pixels)
                    }
                try source.check()
                if cancelled() { throw CancellationError() }
                return result
            }.value
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            return result
        } onCancel: { cancellation.cancel() }
    }
    private final class Ownership: @unchecked Sendable {
        let slot: AskToolPixelBudget.Lease
        let pixels: AskToolPixelBudget.Lease
        init(slot: AskToolPixelBudget.Lease, pixels: AskToolPixelBudget.Lease) { self.slot = slot; self.pixels = pixels }
    }
    private final class Pixels {
        let bytes: NSData
        let lease: AskToolPixelBudget.Lease
        init(_ bytes: Data, _ lease: AskToolPixelBudget.Lease) { self.bytes = bytes as NSData; self.lease = lease }
    }
    private static func image(_ raster: MediaRaster, bytes: Data, lease: AskToolPixelBudget.Lease) throws -> CGImage {
        let pixels = Pixels(bytes, lease)
        let retained = Unmanaged.passRetained(pixels)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels.bytes.bytes, size: pixels.bytes.length,
            releaseData: { info, _, _ in if let info { Unmanaged<Pixels>.fromOpaque(info).release() } }) else {
            retained.release(); throw MediaFailure.unavailable
        }
        guard let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: raster.stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw MediaFailure.unavailable }
        return image
    }
}
