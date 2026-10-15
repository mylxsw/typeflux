import Foundation

/// Preview pixels travel in fixed-name private files, never as encoded original media.
public struct MediaPreviewOptions: Codable, Sendable {
    public static let requestBytes = 32 * 1024
    public static let maxEdge = 4096
    public static let maxPixels = 4 * 1024 * 1024
    public var width: Int
    public var height: Int
    public var page: Int?
    public var passage: String?
    public init(width: Int, height: Int, page: Int? = nil, passage: String? = nil) {
        self.width = width; self.height = height; self.page = page; self.passage = passage
    }
    public func validate() throws {
        guard width > 0, height > 0, width <= Self.maxEdge, height <= Self.maxEdge,
              width * height <= Self.maxPixels, (passage?.utf8.count ?? 0) <= 16 * 1024
        else { throw MediaFailure.tooLarge }
    }
}

public struct MediaRaster: Codable, Sendable {
    public var width: Int
    public var height: Int
    public var stride: Int
    public var bytes: Int
    public var page: Int?
    public init(width: Int, height: Int, page: Int? = nil) {
        self.width = width; self.height = height; self.stride = width * 4
        self.bytes = stride * height; self.page = page
    }
    public func validate(for options: MediaPreviewOptions) throws {
        try options.validate()
        guard width > 0, height > 0, width <= options.width, height <= options.height,
              stride == width * 4, bytes == stride * height
        else { throw MediaFailure.invalidProtocol }
    }
    public static func filename(_ index: Int) -> String { "raster-\(index)" }
}

public struct MediaPreviewResult: Codable, Sendable {
    public var rasters: [MediaRaster]
    public var pages: Int
    public init(rasters: [MediaRaster], pages: Int = 0) { self.rasters = rasters; self.pages = pages }
    public func validate(for request: MediaRequest) throws {
        guard let options = request.preview, !rasters.isEmpty, rasters.count <= 3
        else { throw MediaFailure.invalidProtocol }
        for raster in rasters { try raster.validate(for: options) }
        if request.operation == .previewImage {
            guard rasters.count == 1, pages == 0, rasters[0].page == nil
            else { throw MediaFailure.invalidProtocol }
        } else {
            guard request.operation == .previewPDF, pages > 0 else { throw MediaFailure.invalidProtocol }
            let expected = options.page.flatMap { (1 ... pages).contains($0) ? [$0] : nil }
                ?? Array(1 ... min(3, pages))
            guard rasters.map(\.page) == expected.map(Optional.some) else { throw MediaFailure.invalidProtocol }
        }
    }
}
