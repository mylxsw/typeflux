import CoreGraphics
import CryptoKit
import Foundation

/// Versioned, fixed-size icon pixels. No encoded image parser runs in the UI process.
actor AskLauncherIconDiskCache {
    static let shared = AskLauncherIconDiskCache(directory: TypefluxDataDirectories.cache.appendingPathComponent("LauncherIcons", isDirectory: true))

    private static let edge = 56
    private static let stride = edge * 4
    private static let bytes = edge * stride
    private let directory: URL
    private var currentFingerprints: [String: String]?

    init(directory: URL) { self.directory = directory }

    private func fileURL(path: String, fingerprint: String) -> URL {
        let digest = SHA256.hash(data: Data((path + "\0" + fingerprint).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".rgba"
        return directory.appendingPathComponent(name)
    }

    func load(path: String, fingerprint: String) -> AskFilePreviewPDF.Result? {
        let url = fileURL(path: path, fingerprint: fingerprint)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == Self.bytes,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Self.edge, height: Self.edge, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: Self.stride, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                      CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return .init(images: [image], numbers: [], pages: 0)
    }

    func store(_ result: AskFilePreviewPDF.Result, path: String, fingerprint: String) {
        if let currentFingerprints, currentFingerprints[path] != fingerprint { return }
        guard let image = result.images.first, result.images.count == 1,
              image.width == Self.edge, image.height == Self.edge,
              image.bytesPerRow == Self.stride, image.bitsPerPixel == 32,
              let raw = image.dataProvider?.data else { return }
        let data = raw as Data
        guard data.count == Self.bytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL(path: path, fingerprint: fingerprint), options: .atomic)
        } catch { /* A cache write must never block an icon. */ }
    }

    func prune(keeping fingerprints: [String: String]) {
        currentFingerprints = fingerprints
        let wanted = Set(fingerprints.map { fileURL(path: $0.key, fingerprint: $0.value).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for file in files where file.pathExtension == "rgba" && !wanted.contains(file.lastPathComponent) {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
