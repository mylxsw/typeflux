import AppKit
import UniformTypeIdentifiers
import TypefluxMediaProtocol

/// NSWorkspace and lazy NSImage representations never cross the process boundary.
public enum MediaNativeIconDecoder {
    @MainActor public static func decode(_ request: MediaRequest, directory: URL,
        lookup: @MainActor (MediaNativeIcon) throws -> NSImage = lookup) throws -> MediaResponse {
        try request.validate()
        guard request.operation == .nativeIcon, let icon = request.icon, let options = request.preview
        else { throw MediaFailure.invalidProtocol }
        let image = try lookup(icon)
        let width = options.width, height = options.height
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaFailure.unreadable }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raster = context.makeImage() else { throw MediaFailure.unavailable }
        var response = MediaResponse(id: request.id)
        response.preview = .init(rasters: [try MediaPreviewDecoder.write(raster, index: 0, page: nil, directory: directory)])
        try response.validate(for: request)
        return response
    }

    @MainActor public static func lookup(_ icon: MediaNativeIcon) throws -> NSImage {
        try icon.validate()
        switch icon.kind {
        case .file:
            return NSWorkspace.shared.icon(forFile: icon.value)
        case .type:
            guard let type = UTType(icon.value) else { throw MediaFailure.unreadable }
            return NSWorkspace.shared.icon(for: type)
        }
    }
}
