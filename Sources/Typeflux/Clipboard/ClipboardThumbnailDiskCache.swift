import AppKit
import CryptoKit
import Darwin

/// Disposable, bounded RGBA thumbnails. Encoded media is still decoded only by the worker.
/// All IO runs on background tasks; no pixels are retained between panel sessions.
final class ClipboardThumbnailDiskCache: @unchecked Sendable {
    static let shared = ClipboardThumbnailDiskCache(directory:
        TypefluxDataDirectories.cache.appendingPathComponent("clipboard-thumbnails-v1", isDirectory: true))
    // Include the shelf's 480-pixel single-image cards, but exclude full previews.
    static let maximumEdge = 480
    struct Key {
        let source: URL
        let stamp: ClipboardMediaInfoProvider.Stamp
        let filename: String
    }
    private let directory: URL
    private let byteLimit: Int
    private let itemLimit: Int
    private let lifetime: TimeInterval
    private let lock = NSLock()

    init(directory: URL, byteLimit: Int = 64 * 1024 * 1024, itemLimit: Int = 512,
         lifetime: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory; self.byteLimit = byteLimit; self.itemLimit = itemLimit; self.lifetime = lifetime
    }

    func key(for url: URL, edge: Int) -> Key? {
        guard url.isFileURL, (1...Self.maximumEdge).contains(edge),
              let stamp = try? ClipboardMediaInfoProvider.Stamp(url) else { return nil }
        let version = "\(stamp.device):\(stamp.inode):\(stamp.bytes):\(stamp.modified):\(stamp.modifiedNanos):\(stamp.changed):\(stamp.changedNanos):\(edge)"
        return Key(source: url, stamp: stamp, filename: Self.hash(url.path) + "-" + Self.hash(version) + ".rgba")
    }

    func read(_ key: Key, edge: Int) -> AskFilePreviewPDF.Result? {
        lock.withLock {
            guard (1...Self.maximumEdge).contains(edge), isCurrent(key) else { return nil }
            let url = directory.appendingPathComponent(key.filename)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate,
                  Date().timeIntervalSince(date) < lifetime else { return nil }
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_size <= 12 + Self.maximumEdge * Self.maximumEdge * 4 else { return nil }
            guard let data = try? handle.read(upToCount: 12 + Self.maximumEdge * Self.maximumEdge * 4 + 1),
                  data.count >= 12, data.prefix(4) == Data([84, 70, 67, 49]) else { return nil }
            let width = Self.dimension(data, at: 4), height = Self.dimension(data, at: 8)
            guard width > 0, height > 0, width <= edge, height <= edge,
                  data.count == 12 + width * height * 4, isCurrent(key),
                  let provider = CGDataProvider(data: data.dropFirst(12) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return .init(images: [image], numbers: [], pages: 0)
        }
    }

    func write(_ result: AskFilePreviewPDF.Result, for key: Key, edge: Int) {
        lock.withLock {
            guard (1...Self.maximumEdge).contains(edge), isCurrent(key), result.images.count == 1,
                  let image = result.images.first, image.width > 0, image.height > 0,
                  image.width <= edge, image.height <= edge,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var data = Data([84, 70, 67, 49])
            for dimension in [image.width, image.height] {
                data.append(contentsOf: [24, 16, 8, 0].map { UInt8((dimension >> $0) & 255) })
            }
            data.append(Data(bytes: bytes, count: image.width * image.height * 4))
            guard data.count <= byteLimit, itemLimit > 0 else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(key.filename)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                trim()
            } catch { /* A disposable cache must never prevent preview or paste. */ }
        }
    }

    func remove(for source: URL) {
        lock.withLock {
            let prefix = Self.hash(source.path) + "-"
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func isCurrent(_ key: Key) -> Bool {
        (try? ClipboardMediaInfoProvider.Stamp(key.source)) == key.stamp
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func dimension(_ data: Data, at offset: Int) -> Int {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension == "rgba" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 > $1.2 }
        var bytes = 0, count = 0
        for (url, size, date) in files {
            if Date().timeIntervalSince(date) >= lifetime || count >= itemLimit || size > byteLimit - bytes {
                try? FileManager.default.removeItem(at: url)
            } else { bytes += size; count += 1 }
        }
    }
}
