import AVFoundation
import Foundation

/// Bounded RGB thumbnail of the last retained frame, independent of the encoded ordinal.
struct SemanticVideoProgress: Codable, Equatable {
    var next: Double
    var actual: Double
    var reference: Data
    var complete = false

    var valid: Bool {
        next.isFinite && next >= 0 && actual.isFinite && actual >= 0 && reference.count == 16 * 16 * 4
    }
}

enum SemanticVideoFrames {
    static let recipe = "video-step0.5-tail-rgb16-mean2-max12-actual-v1"
    static let step = 0.5

    static func thumbnail(_ image: CGImage) throws -> Data {
        var bytes = Data(count: 16 * 16 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw AskFileReadError.unavailable }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return bytes
    }

    /// Both average and peak RGB distance must be small. Compare to the last encoded frame,
    /// so a slow visual drift eventually exceeds the threshold instead of disappearing forever.
    static func duplicate(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 1024, rhs.count == lhs.count else { return false }
        var sum = 0, peak = 0
        for index in lhs.indices where index % 4 != 3 {
            let delta = abs(Int(lhs[index]) - Int(rhs[index]))
            sum += delta; peak = max(peak, delta)
        }
        return sum <= 768 * 2 && peak <= 12
    }

    static func extract(_ asset: AVAsset, folder: URL, cursor: SemanticVideoProgress?,
                        emit: (AskFileReadResponse) throws -> Void) throws {
        if let cursor {
            guard cursor.valid else { throw AskFileReadError.protocolError }
        }
        guard cursor?.complete != true else { return }
        guard let metadata = try SemanticAssetMetadata.video(asset) else { return }
        let start = metadata.start
        let duration = metadata.end
        guard start.isFinite, duration.isFinite, duration > start, duration < Double(Int.max) else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1008, height: 1008)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        var next = cursor?.next ?? start, reference = cursor?.reference
        while true {
            try emit(.init(more: true))
            let tail = next >= duration
            let requested = tail ? max(start, duration - 1.0 / 600) : next
            var actual = CMTime.invalid
            let image = try generator.copyCGImage(at: CMTime(seconds: requested, preferredTimescale: 600),
                                                  actualTime: &actual)
            guard actual.seconds.isFinite, actual.seconds >= 0 else { throw AskFileReadError.protocolError }
            let small = try thumbnail(image)
            let repeated = reference.map { duplicate(small, $0) } ?? false
            if !repeated {
                reference = small
            }
            let progress = SemanticVideoProgress(next: tail ? next : next + step, actual: actual.seconds,
                                                 reference: reference!, complete: tail)
            if repeated {
                try emit(.init(more: true, videoProgress: progress))
            } else {
                let path = folder
                    .appendingPathComponent("frame-\(CMTime(seconds: requested, preferredTimescale: 600).value).jpg")
                try SemanticMediaExtractor.write(image, to: path)
                try emit(.init(more: true, media: .init(kind: .image, path: path.path,
                                                        time: actual.seconds, endTime: actual.seconds),
                               videoProgress: progress))
            }
            if tail {
                return
            }
            next = progress.next
        }
    }
}
