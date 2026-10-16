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
    public enum Operation: String, Codable, Sendable { case image, pdf, normalizeImage, previewImage, previewPDF, previewVideo, previewAudio
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
    public var preview: MediaPreviewResult?
    public init(id: UUID, items: [MediaItem] = [], failure: MediaFailure? = nil) {
        self.id = id; self.items = items; self.failure = failure
    }

    /// Structural validation only: never invoke the native decoder in the host.
    public func validate(for request: MediaRequest) throws {
        try request.validate()
        guard version == 1, id == request.id else { throw MediaFailure.invalidProtocol }
        if let failure {
            guard items.isEmpty, preview == nil, normalization == nil else { throw MediaFailure.invalidProtocol }
            throw failure
        }
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
