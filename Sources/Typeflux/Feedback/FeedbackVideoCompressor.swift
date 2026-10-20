import AppKit
import AVFoundation

enum FeedbackMediaError: LocalizedError, Equatable {
    case videoTooLong(maxMinutes: Int)
    case videoUnreadable
    case compressionFailed(String)
    /// The compressed video is still over the limit; carries its size.
    case videoStillTooLarge(compressedBytes: Int64)

    var errorDescription: String? {
        switch self {
        case let .videoTooLong(maxMinutes):
            String(format: L("feedback.attachment.error.videoTooLong"), maxMinutes)
        case .videoUnreadable:
            L("feedback.attachment.error.videoUnreadable")
        case let .compressionFailed(message):
            String(format: L("feedback.attachment.error.compressionFailed"), message)
        case let .videoStillTooLarge(bytes):
            String(
                format: L("feedback.attachment.error.videoStillTooLarge"),
                FeedbackAttachmentPolicy.formattedSize(bytes),
                FeedbackAttachmentPolicy.formattedSize(FeedbackAttachmentPolicy.maxVideoBytes)
            )
        }
    }
}

/// Re-encodes a recording to 720p H.264 (mp4) before it is uploaded.
enum FeedbackVideoCompressor {
    /// Longer recordings take too long to compress and are refused up front.
    static let maxDurationSeconds: Double = 10 * 60

    static func compress(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedFeedbackFile {
        let asset = AVURLAsset(url: url)
        let duration = try await validatedDuration(of: asset)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-feedback-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await export(asset, to: output, progress: progress)
        progress(1)

        let size = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0 else { throw FeedbackMediaError.compressionFailed("") }
        guard size <= FeedbackAttachmentPolicy.maxVideoBytes else {
            throw FeedbackMediaError.videoStillTooLarge(compressedBytes: size)
        }
        let data = try Data(contentsOf: output)
        let baseName = (url.lastPathComponent as NSString).deletingPathExtension
        return await PreparedFeedbackFile(
            data: data,
            filename: (baseName.isEmpty ? "feedback-video" : baseName) + ".mp4",
            contentType: "video/mp4",
            kind: .video,
            thumbnail: thumbnail(of: asset),
            durationSeconds: duration
        )
    }

    /// The asset's length in seconds; throws when it cannot be played or is too long to compress.
    private static func validatedDuration(of asset: AVURLAsset) async throws -> Double {
        let duration: Double
        do {
            duration = try await asset.load(.duration).seconds
            guard try await asset.load(.isPlayable), duration.isFinite, duration > 0 else {
                throw FeedbackMediaError.videoUnreadable
            }
        } catch let error as FeedbackMediaError {
            throw error
        } catch {
            throw FeedbackMediaError.videoUnreadable
        }
        guard duration <= maxDurationSeconds else {
            throw FeedbackMediaError.videoTooLong(maxMinutes: Int(maxDurationSeconds / 60))
        }
        return duration
    }

    /// Exports `asset` as 720p mp4 to `output`, reporting progress and honouring cancellation.
    private static func export(
        _ asset: AVURLAsset,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw FeedbackMediaError.compressionFailed(L("feedback.attachment.error.videoUnreadable"))
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }

        // AVAssetExportSession raises when it is started after it was cancelled, so a cancellation
        // that arrives before the export starts must skip the start instead of cancelling the session.
        let gate = ExportGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if gate.markStarted() {
                    session.exportAsynchronously { continuation.resume() }
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            if gate.markCancelled() {
                session.cancelExport()
            }
        }
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw FeedbackMediaError.compressionFailed(session.error?.localizedDescription ?? "")
        }
    }

    private static func thumbnail(of asset: AVAsset) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// Orders the start and the cancellation of one export, which may race.
private final class ExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    /// Returns false when the export was cancelled before it could start.
    func markStarted() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            started = true
            return true
        }
    }

    /// Returns true when the export is already running and must be cancelled.
    func markCancelled() -> Bool {
        lock.withLock {
            cancelled = true
            return started
        }
    }
}
