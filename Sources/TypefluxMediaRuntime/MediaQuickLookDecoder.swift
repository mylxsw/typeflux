import AppKit
import Darwin
import QuickLookThumbnailing
import TypefluxMediaProtocol

/// Disposable child owns the native request and all lazy representations.
public enum MediaQuickLookDecoder {
    public typealias Generate = @MainActor (URL, MediaPreviewOptions, MediaQuickLook.Representation) async throws -> CGImage

    @MainActor public static func decode(_ request: MediaRequest, directory: URL,
                                         generate: Generate = generate) async throws -> MediaResponse {
        try request.validate()
        guard request.operation == .quickLook, let target = request.quickLook, let options = request.preview
        else { throw MediaFailure.invalidProtocol }
        let url = URL(fileURLWithPath: target.path)
        let before = try snapshot(url)
        let image = try await generate(url, options, target.representation)
        try Task.checkCancellation()
        guard before == (try snapshot(url)) else { throw MediaFailure.unreadable }
        // A provider may return an icon representation larger than the requested thumbnail.
        guard image.width > 0, image.height > 0, image.width <= 100_000, image.height <= 100_000,
              image.width <= 100_000_000 / image.height else { throw MediaFailure.tooLarge }
        let scale = min(1, min(Double(options.width) / Double(image.width), Double(options.height) / Double(image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaFailure.unavailable }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.makeImage() else { throw MediaFailure.unavailable }
        var response = MediaResponse(id: request.id)
        response.preview = .init(rasters: [try MediaPreviewDecoder.write(pixels, index: 0, page: nil, directory: directory)])
        try response.validate(for: request)
        return response
    }

    @MainActor public static func generate(_ url: URL, options: MediaPreviewOptions,
                                           representation: MediaQuickLook.Representation) async throws -> CGImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: .init(width: options.width, height: options.height),
            scale: 1, representationTypes: representation == .all ? .all : .thumbnail)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            try Task.checkCancellation()
            return result.cgImage
        } onCancel: { QLThumbnailGenerator.shared.cancel(request) }
    }

    private struct Stamp: Equatable {
        let path: String; let device: dev_t; let inode: ino_t; let bytes: off_t
        let modified: Int; let modifiedNanos: Int; let changed: Int; let changedNanos: Int
    }
    /// Bound native input enumeration without copying packages or following nested links.
    private static func snapshot(_ original: URL) throws -> [Stamp] {
        let root = original.resolvingSymlinksInPath()
        var total: Int64 = 0, stamps: [Stamp] = []
        func append(_ url: URL) throws -> Bool {
            try Task.checkCancellation()
            var info = stat()
            var mount = statfs()
            guard url.path.utf8.count <= 4096, lstat(url.path, &info) == 0,
                  info.st_flags & UInt32(SF_DATALESS) == 0,
                  statfs(url.path, &mount) == 0, mount.f_flags & UInt32(MNT_LOCAL) != 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { throw MediaFailure.unreadable }
            guard stamps.count < MediaQuickLook.maximumEntries, info.st_size >= 0,
                  info.st_size <= MediaQuickLook.maximumBytes - total else { throw MediaFailure.tooLarge }
            total += info.st_size
            stamps.append(.init(path: url.path, device: info.st_dev, inode: info.st_ino, bytes: info.st_size,
                modified: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                changed: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec))
            return info.st_mode & S_IFMT == S_IFDIR
        }
        if try append(root) {
            guard ["pages", "numbers", "key", "keynote", "rtfd", "sketch"].contains(root.pathExtension.lowercased()) else { throw MediaFailure.unreadable }
            var failed = false
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in failed = true; return false }) else { throw MediaFailure.unreadable }
            while let entry = entries.nextObject() as? URL { _ = try append(entry) }
            guard !failed else { throw MediaFailure.unreadable }
        }
        return stamps.sorted { $0.path < $1.path }
    }
}
