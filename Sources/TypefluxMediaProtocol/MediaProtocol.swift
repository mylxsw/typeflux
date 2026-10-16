import Foundation

public enum MediaLimits {
    public static let inputBytes = 50_000_000
    public static let responseBytes = 16 * 1024 * 1024
    public static let requestBytes = 1024
    public static let imageBytes = 1_500_000
    public static let textCharacters = 200_000
    public static let imageLongEdge = 2048
    public static let scannedPages = 8
}

public enum MediaFailure: String, Error, Codable, Sendable {
    case unreadable, tooLarge, unavailable, invalidProtocol
}

public struct MediaRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case image, pdf, inspectWorkflowImage, copyWorkflowImage, validateGeneratedImage, normalizeImage, previewImage, previewPDF, previewVideo, previewAudio
        public var isWorkflowImage: Bool { self == .inspectWorkflowImage || self == .copyWorkflowImage }
        public var isAV: Bool { self == .previewVideo || self == .previewAudio }
    }
    public var version = 1
    public var id: UUID
    public var operation: Operation
    public var normalization: MediaImageType?
    public var preview: MediaPreviewOptions?
    public init(id: UUID = UUID(), operation: Operation) { self.id = id; self.operation = operation }
    public func validate() throws {
        guard (operation == .normalizeImage) == (normalization != nil) else { throw MediaFailure.invalidProtocol }
        guard version == 1 else { throw MediaFailure.invalidProtocol }
        if operation == .previewImage || operation == .previewPDF || operation.isAV {
            guard let preview else { throw MediaFailure.invalidProtocol }
            try preview.validate()
            if preview.imageType != nil, operation != .previewImage { throw MediaFailure.invalidProtocol }
            if operation.isAV, preview.page != nil || preview.passage != nil { throw MediaFailure.invalidProtocol }
        } else if preview != nil { throw MediaFailure.invalidProtocol }
    }
}

public struct MediaItem: Codable, Sendable {
    public var image: String?
    public var text: String?
    public var truncated: Bool?
    public var pages: Int?
    public var page: Int?
    public init(image: String? = nil, text: String? = nil, truncated: Bool? = nil,
                pages: Int? = nil, page: Int? = nil) {
        self.image = image; self.text = text; self.truncated = truncated; self.pages = pages; self.page = page
    }
}

public struct MediaResponse: Codable, Sendable {
    public var version = 1
    public var id: UUID
    public var items: [MediaItem]
    public var failure: MediaFailure?
    public var normalization: MediaImageType?
    public var workflowImage: MediaWorkflowImage?
    public var generatedImage: MediaGeneratedImage?
    public var preview: MediaPreviewResult?
    public init(id: UUID, items: [MediaItem] = [], failure: MediaFailure? = nil) {
        self.id = id; self.items = items; self.failure = failure
    }

    /// Structural validation only: never invoke the native decoder in the host.
    public func validate(for request: MediaRequest) throws {
        try request.validate()
        guard version == 1, id == request.id else { throw MediaFailure.invalidProtocol }
        if let failure {
            guard items.isEmpty, preview == nil, normalization == nil, generatedImage == nil, workflowImage == nil else { throw MediaFailure.invalidProtocol }
            throw failure
        }
        if request.operation.isWorkflowImage {
            guard items.isEmpty, preview == nil, normalization == nil, generatedImage == nil, let workflowImage else { throw MediaFailure.invalidProtocol }
            try workflowImage.validate(copying: request.operation == .copyWorkflowImage)
            return
        }
        guard workflowImage == nil else { throw MediaFailure.invalidProtocol }
        if request.operation == .validateGeneratedImage {
            guard items.isEmpty, preview == nil, normalization == nil, let generatedImage else { throw MediaFailure.invalidProtocol }
            try generatedImage.validate()
            return
        }
        guard generatedImage == nil else { throw MediaFailure.invalidProtocol }
        guard normalization == request.normalization else { throw MediaFailure.invalidProtocol }
        if request.preview != nil {
            guard items.isEmpty, let preview else { throw MediaFailure.invalidProtocol }
            try preview.validate(for: request)
            return
        }
        guard preview == nil else { throw MediaFailure.invalidProtocol }
        guard !items.isEmpty, items.count <= MediaLimits.scannedPages,
              (request.operation != .image && request.operation != .normalizeImage) || items.count == 1 else { throw MediaFailure.invalidProtocol }
        var previous = 0
        for item in items {
            if let image = item.image {
                let prefix = "data:image/jpeg;base64,"
                guard item.text == nil, item.truncated == nil, item.pages == nil,
                      image.utf8.count <= MediaLimits.imageBytes, image.hasPrefix(prefix),
                      let bytes = Data(base64Encoded: String(image.dropFirst(prefix.count))),
                      MediaJPEG.isNormalized(bytes) else { throw MediaFailure.invalidProtocol }
                if request.operation == .pdf {
                    guard let page = item.page, page > previous, page <= MediaLimits.scannedPages
                    else { throw MediaFailure.invalidProtocol }
                    previous = page
                } else if item.page != nil { throw MediaFailure.invalidProtocol }
            } else {
                guard request.operation == .pdf, items.count == 1, item.page == nil,
                      let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= MediaLimits.textCharacters * 4, text.count <= MediaLimits.textCharacters,
                      let pages = item.pages, pages > 0 else { throw MediaFailure.invalidProtocol }
            }
        }
    }
}

/// Metadata for original generated bytes; no re-encoding or provider replay.
public struct MediaGeneratedImage: Codable, Sendable, Equatable {
    public var mediaType: String
    public var width: Int
    public var height: Int
    public init(mediaType: String, width: Int, height: Int) {
        self.mediaType = mediaType; self.width = width; self.height = height
    }
    public func validate() throws {
        guard ["image/png", "image/jpeg"].contains(mediaType), width > 0, height > 0,
              width <= 8192, height <= 8192, width <= 16_777_216 / height else { throw MediaFailure.invalidProtocol }
    }
}
