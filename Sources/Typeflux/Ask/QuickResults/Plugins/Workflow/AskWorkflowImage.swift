import CryptoKit
import Foundation
import ImageIO

/// What `display: image` shows: the image file a script named, or the one it printed
/// as a data URL, saved to the workflow's cache folder so it can be revealed in Finder
/// like any other. See `docs/design/workflow-gallery-output-actions.md` §3.2.
enum AskWorkflowImage {
    /// Larger data URLs are not images a launcher card should hold.
    static let maximumDataBytes = 20 * 1024 * 1024

    enum Failure: Error, Equatable {
        /// The path names no file.
        case notFound(String)
        /// The file or data is not an image this Mac can read.
        case notImage
    }

    /// The image `stdout` names: a `data:image/…;base64,…` URL, else its first line as
    /// a path (absolute, under `~`, or relative to the workflow's folder).
    static func resolve(_ stdout: String, folder: URL, cache: URL, home: String,
                        fileManager: FileManager = .default) -> Result<AskPluginImage, Failure> {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("data:") {
            guard let data = dataURL(text) else { return .failure(.notImage) }
            return save(data, in: cache, fileManager: fileManager)
        }
        let line = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let path = line.hasPrefix("file://") ? URL(string: line)?.path ?? line : line
        guard !path.isEmpty, let url = AskWorkflowActionRunner.file(path, folder: folder, home: home),
              fileManager.fileExists(atPath: url.path) else { return .failure(.notFound(line)) }
        return image(at: url).map { .success($0) } ?? .failure(.notImage)
    }

    /// The bytes of a base64 image data URL; nil for anything else.
    static func dataURL(_ text: String) -> Data? {
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[..<comma].lowercased()
        guard header.hasPrefix("data:image/"), header.hasSuffix(";base64") else { return nil }
        let payload = text[text.index(after: comma)...].filter { !$0.isWhitespace }
        guard payload.count <= maximumDataBytes / 3 * 4 + 4,
              let data = Data(base64Encoded: String(payload)) else { return nil }
        return data
    }

    /// Writes data-URL bytes once, named by their hash, so running again reuses the file.
    private static func save(_ data: Data, in cache: URL,
                             fileManager: FileManager) -> Result<AskPluginImage, Failure> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, size(of: source) != nil else {
            return .failure(.notImage)
        }
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let folder = cache.appendingPathComponent("images", isDirectory: true)
        let url = folder.appendingPathComponent(digest).appendingPathExtension(fileExtension(for: type))
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            return .failure(.notImage)
        }
        return image(at: url).map { .success($0) } ?? .failure(.notImage)
    }

    /// The image at `url` with its size in points; nil when it is not an image.
    static func image(at url: URL) -> AskPluginImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let size = size(of: source) else {
            return nil
        }
        return AskPluginImage(url: url, width: size.width, height: size.height)
    }

    /// Pixel size, halved for images marked as 144 dpi (a Retina screenshot shows at its real size).
    private static func size(of source: CGImageSource) -> (width: Double, height: Double)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi >= 144 ? 2.0 : 1.0
        return (width / scale, height / scale)
    }

    private static func fileExtension(for type: String) -> String {
        switch type {
        case "public.jpeg": "jpg"
        case "com.compuserve.gif": "gif"
        case "org.webmproject.webp": "webp"
        case "public.tiff": "tiff"
        case "public.heic": "heic"
        default: "png"
        }
    }
}
