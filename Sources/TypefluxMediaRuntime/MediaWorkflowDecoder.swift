import Foundation
import ImageIO
import TypefluxMediaProtocol

/// Workflow results are already produced. Inspection/copying never executes a producer.
public enum MediaWorkflowDecoder {
    public static func decode(_ request: MediaRequest, directory: URL) throws -> MediaResponse {
        try request.validate()
        guard request.operation.isWorkflowImage else { throw MediaFailure.invalidProtocol }
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent("input"))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MediaWorkflowImage.inputBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= MediaWorkflowImage.inputBytes else { throw MediaFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let identifier = CGImageSourceGetType(source) as String?, let format = MediaWorkflowFormat(rawValue: identifier),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw MediaFailure.unreadable }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        guard dpi.isFinite else { throw MediaFailure.unreadable }
        var metadata = MediaWorkflowImage(format: format, width: width, height: height, scale: dpi >= 144 ? 2 : 1)
        do { try metadata.validate(copying: false) } catch { throw MediaFailure.tooLarge }
        if request.operation == .copyWorkflowImage {
            guard width <= 8192, height <= 8192, width <= 16_777_216 / height,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                ] as CFDictionary) else { throw MediaFailure.tooLarge }
            let png = try encode(image, type: "public.png", scale: metadata.scale), tiff = try encode(image, type: "public.tiff", scale: metadata.scale)
            guard png.count <= MediaWorkflowImage.copyBytes, tiff.count <= MediaWorkflowImage.copyBytes - png.count
            else { throw MediaFailure.tooLarge }
            try png.write(to: directory.appendingPathComponent("clipboard-png"), options: .withoutOverwriting)
            try tiff.write(to: directory.appendingPathComponent("clipboard-tiff"), options: .withoutOverwriting)
            metadata.pngBytes = png.count; metadata.tiffBytes = tiff.count
        }
        var response = MediaResponse(id: request.id); response.workflowImage = metadata
        try response.validate(for: request)
        return response
    }
    private static func encode(_ image: CGImage, type: String, scale: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw MediaFailure.unavailable }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: scale * 72, kCGImagePropertyDPIHeight: scale * 72] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= MediaWorkflowImage.copyBytes else { throw MediaFailure.tooLarge }
        return data as Data
    }
}
