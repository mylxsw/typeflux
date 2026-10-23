import Darwin
import Foundation
import ImageIO

/// The producer retains the private file until delivery is acknowledged. A
/// failed delivery can still save the original through the existing fallback.
enum FeatureImageTransfer {
    static let maximumBytes = 128 * 1024 * 1024
    static func directory(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-follow-up-" + id.uuidString)
    }
    static func write(_ data: Data, id: UUID) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw FeatureRPC.Failure.invalidMessage }
        let root = directory(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: root.appendingPathComponent("image.png"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("image.png").path)
        } catch { remove(id); throw error }
    }
    static func read(_ id: UUID) throws -> CGImage {
        let root = directory(id)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw FeatureRPC.Failure.invalidMessage }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw FeatureRPC.Failure.unavailable }
        defer { close(parent) }
        let fd = openat(parent, "image.png", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FeatureRPC.Failure.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= maximumBytes,
              let data = try file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 134_217_728 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw FeatureRPC.Failure.invalidMessage }
        return image
    }
    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: directory(id)) }
}
