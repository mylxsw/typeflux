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
    public var start: Double?
    public var container: MediaAVContainer?
    public var imageType: MediaImageType?
    public init(width: Int, height: Int, page: Int? = nil, passage: String? = nil, start: Double? = nil, container: MediaAVContainer? = nil, imageType: MediaImageType? = nil) {
        self.width = width; self.height = height; self.page = page; self.passage = passage; self.start = start; self.container = container; self.imageType = imageType
    }
    public func validate() throws {
        guard width > 0, height > 0, width <= Self.maxEdge, height <= Self.maxEdge,
              width * height <= Self.maxPixels, (passage?.utf8.count ?? 0) <= 16 * 1024, start?.isFinite != false
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
    public var duration: Double?
    public var start: Double?
    public var waveform: [Float]?
    public var imageType: MediaImageType?
    public init(rasters: [MediaRaster], pages: Int = 0) { self.rasters = rasters; self.pages = pages }
    public func validate(for request: MediaRequest) throws {
        guard let options = request.preview, rasters.count <= 3
        else { throw MediaFailure.invalidProtocol }
        try options.validate()
        guard imageType == options.imageType else { throw MediaFailure.invalidProtocol }
        for raster in rasters { try raster.validate(for: options) }
        if request.operation.isAV {
            guard pages == 0, let duration, let start, duration.isFinite, duration >= 0,
                  duration <= MediaAVLimits.maximumDuration, start == MediaAVLimits.start(options.start ?? 0, duration: duration)
            else { throw MediaFailure.invalidProtocol }
            if request.operation == .previewAudio {
                guard rasters.isEmpty, let waveform, waveform.count == 80,
                      waveform.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
                else { throw MediaFailure.invalidProtocol }
            } else {
                guard rasters.count == 1, rasters[0].page == nil, waveform == nil
                else { throw MediaFailure.invalidProtocol }
            }
            return
        }
        guard !rasters.isEmpty, duration == nil, start == nil, waveform == nil else { throw MediaFailure.invalidProtocol }
        if request.operation.isRecordingPoster || request.operation == .quickLook || request.operation == .previewImage || request.operation == .nativeIcon {
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

public enum MediaAVLimits {
    public static let inputBytes = 512 * 1024 * 1024
    public static let maximumDuration = Double(Int32.max)
    public static let chunkBytes = 4 * 1024 * 1024
    public static let decodedBytes = 128 * 1024 * 1024
    public static func start(_ requested: Double, duration: Double) -> Double {
        requested.isFinite ? max(0, min(max(0, duration - 0.001), requested)) : 0
    }
}

/// A format hint only, never an arbitrary child-selected path or URL.
public enum MediaAVContainer: String, Codable, Sendable {
    case mp4, mov, m4v, avi, mkv, webm, mp3, m4a, aac, wav, aiff, aif, flac, ogg, caf
}

/// Declared type checked against the native decoder inside the child.
public enum MediaImageType: String, Codable, Sendable {
    case png = "image/png", jpeg = "image/jpeg", gif = "image/gif"
    public var identifier: String {
        switch self { case .png: "public.png"; case .jpeg: "public.jpeg"; case .gif: "com.compuserve.gif" }
    }
}

/// A native icon lookup, never an instruction to decode the file as image data.
public struct MediaNativeIcon: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case file, type, application, fileExtension }
    public var kind: Kind
    public var value: String
    public init(kind: Kind, value: String) { self.kind = kind; self.value = value }
    public func validate() throws {
        guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= (kind == .file ? 4096 : 256),
              kind != .file || value.hasPrefix("/"),
              kind != .type || value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-".unicodeScalars.contains($0) })
        else { throw MediaFailure.invalidProtocol }
        if kind == .application || kind == .fileExtension {
            guard value.utf8.count <= (kind == .application ? 256 : 64),
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) })
            else { throw MediaFailure.invalidProtocol }
        }
    }
}
