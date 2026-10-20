import Foundation

/// What kind of file a feedback attachment is; each kind has its own handling and size limit.
enum FeedbackAttachmentKind: String, Equatable, Sendable {
    case image, video, file

    /// The value the API receives in `attachments[].kind`.
    var apiValue: String {
        rawValue
    }
}

/// Why a file cannot be attached. Rejected files never enter the feedback.
enum FeedbackAttachmentRejection: Equatable, Sendable {
    case unsupportedType(filename: String)
    case tooLarge(filename: String, limitBytes: Int64)
    case tooMany(limit: Int)

    var message: String {
        switch self {
        case let .unsupportedType(filename):
            String(format: L("feedback.attachment.error.unsupported"), filename)
        case let .tooLarge(filename, limitBytes):
            String(
                format: L("feedback.attachment.error.tooLarge"),
                filename,
                FeedbackAttachmentPolicy.formattedSize(limitBytes)
            )
        case let .tooMany(limit):
            String(format: L("feedback.attachment.error.tooMany"), limit)
        }
    }
}

/// The type, size and count rules for feedback attachments (GUL-427).
enum FeedbackAttachmentPolicy {
    static let maxAttachmentCount = 6
    static let maxImageBytes: Int64 = 3 * 1024 * 1024
    static let maxVideoBytes: Int64 = 50 * 1024 * 1024
    static let maxTextBytes: Int64 = 5 * 1024 * 1024
    static let maxDocumentBytes: Int64 = 10 * 1024 * 1024

    private static let imageExtensions: Set = ["png", "jpg", "jpeg", "heic", "webp", "gif"]
    private static let videoExtensions: Set = ["mov", "mp4", "m4v"]
    private static let textExtensions: Set = ["txt", "log", "md"]
    private static let documentExtensions: Set = ["docx"]

    private static let contentTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic",
        "webp": "image/webp", "gif": "image/gif",
        "mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/mp4",
        "txt": "text/plain", "log": "text/plain", "md": "text/markdown",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ]

    /// The kind for `filename`, or nil when the extension is not supported.
    static func kind(forFilename filename: String) -> FeedbackAttachmentKind? {
        let ext = fileExtension(filename)
        if imageExtensions.contains(ext) {
            return .image
        }
        if videoExtensions.contains(ext) {
            return .video
        }
        if textExtensions.contains(ext) || documentExtensions.contains(ext) {
            return .file
        }
        return nil
    }

    static func contentType(forFilename filename: String) -> String? {
        contentTypes[fileExtension(filename)]
    }

    /// The largest size the file may have when it is uploaded (after any compression).
    static func uploadLimit(forFilename filename: String) -> Int64? {
        let ext = fileExtension(filename)
        if imageExtensions.contains(ext) {
            return maxImageBytes
        }
        if videoExtensions.contains(ext) {
            return maxVideoBytes
        }
        if textExtensions.contains(ext) {
            return maxTextBytes
        }
        if documentExtensions.contains(ext) {
            return maxDocumentBytes
        }
        return nil
    }

    /// Whether the file is compressed before it is checked against the upload limit.
    /// GIFs stay as they are so the animation survives.
    static func isCompressed(filename: String) -> Bool {
        let ext = fileExtension(filename)
        return ext != "gif" && (imageExtensions.contains(ext) || videoExtensions.contains(ext))
    }

    /// Checks a file before it is added. Sizes of images and videos are checked after
    /// compression, so only files that are never compressed are size-checked here.
    static func validate(filename: String, sizeBytes: Int64, currentCount: Int) -> FeedbackAttachmentRejection? {
        guard currentCount < maxAttachmentCount else { return .tooMany(limit: maxAttachmentCount) }
        guard let limit = uploadLimit(forFilename: filename) else {
            return .unsupportedType(filename: filename)
        }
        if !isCompressed(filename: filename), sizeBytes > limit {
            return .tooLarge(filename: filename, limitBytes: limit)
        }
        return nil
    }

    /// Checks the size an attachment has after compression.
    static func validateUploadSize(filename: String, sizeBytes: Int64) -> FeedbackAttachmentRejection? {
        guard let limit = uploadLimit(forFilename: filename) else {
            return .unsupportedType(filename: filename)
        }
        return sizeBytes > limit ? .tooLarge(filename: filename, limitBytes: limit) : nil
    }

    static func formattedSize(_ bytes: Int64) -> String {
        // Binary units, so the limits read as 3 MB, 50 MB and not 3.1 MB, 52.4 MB.
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private static func fileExtension(_ filename: String) -> String {
        (filename as NSString).pathExtension.lowercased()
    }
}
