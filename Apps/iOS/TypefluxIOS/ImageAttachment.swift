import UIKit

enum ImageAttachment {
    static func dataURL(_ data: Data) throws -> String {
        guard let image = UIImage(data: data), image.size.width > 0,
              image.size.height > 0 else { throw ImageError.invalid }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.75) else { throw ImageError.invalid }
        let encoded = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        guard encoded.utf8.count <= 2_800_000 else { throw ImageError.tooLarge }
        return encoded
    }

    static func decode(_ value: String) -> UIImage? {
        let prefix = "data:image/jpeg;base64,"
        guard value.hasPrefix(prefix), value.utf8.count <= 2_800_000,
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { return nil }
        return UIImage(data: data)
    }

    enum ImageError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: "This photo could not be read. Please choose another image."
            case .tooLarge: "This photo is too large. Please choose a smaller image."
            }
        }
    }
}
