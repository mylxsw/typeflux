import AppKit

enum FeedbackAttachmentState: Equatable {
    /// Being compressed or read; `progress` is 0...1 and nil when it is not measurable.
    case preparing(progress: Double?)
    case uploading
    case uploaded(String)
    case failed(String)
    /// Over its size limit even after compression. The block stays in place so the user sees why.
    case rejected(String)

    var isReady: Bool {
        if case .uploaded = self {
            return true
        }
        return false
    }

    var isInProgress: Bool {
        switch self {
        case .preparing, .uploading: true
        case .uploaded, .failed, .rejected: false
        }
    }

    var isBlockingSubmit: Bool {
        switch self {
        case .uploaded: false
        case .preparing, .uploading, .failed, .rejected: true
        }
    }

    var uploadedURL: String? {
        if case let .uploaded(url) = self {
            return url
        }
        return nil
    }
}

struct FeedbackAttachment: Identifiable {
    let id: UUID
    var filename: String
    var kind: FeedbackAttachmentKind
    var contentType: String
    /// The size that is uploaded; 0 until preparation has finished.
    var sizeBytes: Int64
    /// The size of the file the user picked, shown next to the compressed size.
    var originalSizeBytes: Int64
    var durationSeconds: Double?
    var thumbnail: NSImage?
    var state: FeedbackAttachmentState
    /// The sign-in that uploaded the file; set when the upload finishes.
    var uploadOwner: FeedbackUploadOwner?

    init(
        id: UUID = UUID(),
        filename: String,
        kind: FeedbackAttachmentKind = .image,
        contentType: String = "image/jpeg",
        sizeBytes: Int64 = 0,
        originalSizeBytes: Int64 = 0,
        durationSeconds: Double? = nil,
        thumbnail: NSImage? = nil,
        state: FeedbackAttachmentState,
        uploadOwner: FeedbackUploadOwner? = nil
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.originalSizeBytes = originalSizeBytes
        self.durationSeconds = durationSeconds
        self.thumbnail = thumbnail
        self.state = state
        self.uploadOwner = uploadOwner
    }
}

/// One uploaded attachment as the feedback API receives it.
struct FeedbackAttachmentPayload: Encodable, Equatable {
    let url: String
    let filename: String
    let contentType: String
    let sizeBytes: Int64
    let kind: String

    enum CodingKeys: String, CodingKey {
        case url, filename, kind
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
    }
}
