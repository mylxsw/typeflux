import AVFoundation
import ImageIO
import TypefluxMediaProtocol

/// A single saved/recovery poster; no waveform scan, playback or original-file writes.
public enum MediaRecordingPosterDecoder {
    public static func decode(_ request: MediaRequest, directory: URL) async throws -> MediaResponse {
        try request.validate()
        guard request.operation.isRecordingPoster else { throw MediaFailure.invalidProtocol }
        let gif = request.operation == .recordingPosterGIF
        let input = directory.appendingPathComponent("input")
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= (gif ? MediaLimits.inputBytes : MediaRecordingTimeline.inputBytes) else { throw MediaFailure.tooLarge }
        let image: CGImage
        if gif {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "com.compuserve.gif",
                  (1...300).contains(CGImageSourceGetCount(source)),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw MediaFailure.unreadable }
            try size(width.doubleValue, height.doubleValue)
            let edge = max(1, min(200, 120 * width.doubleValue / height.doubleValue))
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(edge, min(120, 200 * height.doubleValue / width.doubleValue)))
            ] as CFDictionary) else { throw MediaFailure.unreadable }
            image = decoded
        } else {
            let hinted = directory.appendingPathComponent("poster.mov")
            try FileManager.default.linkItem(at: input, to: hinted)
            defer { try? FileManager.default.removeItem(at: hinted) }
            let asset = AVURLAsset(url: hinted, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            image = try await withTaskCancellationHandler {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaFailure.unreadable }
                let dimensions = try await track.load(.naturalSize)
                try size(dimensions.width, dimensions.height)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = .init(width: 200, height: 120)
                defer { generator.cancelAllCGImageGeneration() }
                return try generator.copyCGImage(at: .zero, actualTime: nil)
            } onCancel: { asset.cancelLoading() }
        }
        try Task.checkCancellation()
        guard image.width <= 200, image.height <= 120 else { throw MediaFailure.tooLarge }
        let raster = try MediaPreviewDecoder.write(image, index: 0, page: nil, directory: directory)
        var response = MediaResponse(id: request.id); response.preview = .init(rasters: [raster])
        try response.validate(for: request)
        return response
    }
    public static func size(_ width: Double, _ height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 16_777_216 else { throw MediaFailure.tooLarge }
    }
}
