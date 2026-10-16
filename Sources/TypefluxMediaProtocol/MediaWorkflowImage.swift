import Foundation

public enum MediaWorkflowFormat: String, Codable, Sendable {
    case png = "public.png", jpeg = "public.jpeg", gif = "com.compuserve.gif"
    case webp = "org.webmproject.webp", tiff = "public.tiff", heic = "public.heic"
    public var fileExtension: String {
        switch self { case .jpeg: "jpg"; case .png: "png"; case .gif: "gif"; case .webp: "webp"; case .tiff: "tiff"; case .heic: "heic" }
    }
}

public struct MediaWorkflowImage: Codable, Sendable {
    public static let inputBytes = 20 * 1024 * 1024
    public static let copyBytes = 80 * 1024 * 1024
    public var format: MediaWorkflowFormat
    public var width: Int
    public var height: Int
    public var scale: Int
    public var pngBytes: Int?
    public var tiffBytes: Int?
    public init(format: MediaWorkflowFormat, width: Int, height: Int, scale: Int) {
        self.format = format; self.width = width; self.height = height; self.scale = scale
    }
    public func validate(copying: Bool) throws {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              width <= 100_000_000 / height, scale == 1 || scale == 2 else { throw MediaFailure.invalidProtocol }
        if copying {
            guard width <= 8192, height <= 8192, width <= 16_777_216 / height,
                  let pngBytes, let tiffBytes, pngBytes > 0, tiffBytes > 0,
                  pngBytes <= Self.copyBytes, tiffBytes <= Self.copyBytes - pngBytes else { throw MediaFailure.invalidProtocol }
        } else if pngBytes != nil || tiffBytes != nil { throw MediaFailure.invalidProtocol }
    }
}
