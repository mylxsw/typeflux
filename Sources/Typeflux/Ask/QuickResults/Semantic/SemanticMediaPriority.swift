import Foundation

enum SemanticMediaPriority: Int, CaseIterable, Sendable {
    case document, image, audio, video

    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "aiff", "aif", "ogg", "opus", "caf"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
    static let extensions = images.union(audioExtensions).union(videoExtensions)

    static func of(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        if images.contains(ext) {
            return .image
        }
        if audioExtensions.contains(ext) {
            return .audio
        }
        if videoExtensions.contains(ext) {
            return .video
        }
        return .document
    }
}

struct SemanticMediaInput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, audio }
    var kind: Kind
    var path: String
    var time: TimeInterval?
    var endTime: TimeInterval?
}

enum SemanticMediaInputError: Error { case unreadable }

protocol SemanticMediaEmbedding: AnyObject {
    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float]
    func release()
}

extension SemanticMediaEmbedding { func release() {} }

/// Resume only a contiguous committed prefix of a verified media job. Video frames precede audio.
struct SemanticMediaCursor: Codable, Equatable {
    var nextOrdinal = 0
    var videoFrames = 0
    var imageDone = false
    /// Next uncommitted window start; it can precede the covered endpoint because of overlap.
    var audioUntil: Double = 0
    var audioCoveredUntil: Double = 0
    var videoProgress: SemanticVideoProgress?
}
