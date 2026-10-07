import CryptoKit
import Foundation

/// A clipboard payload captured from the system pasteboard, before it is stored.
enum ClipboardCapture: Equatable {
    case text(String)
    /// PNG-encoded image data copied without a backing file (screenshots, web images).
    case image(png: Data, pixelWidth: Int, pixelHeight: Int)
    /// One or more files copied in Finder or another file manager.
    case files([URL])

    /// Stable identity used to collapse repeated copies of the same content.
    var contentHash: String {
        switch self {
        case let .text(text):
            Self.sha256Hex(Data(("text:" + text).utf8))
        case let .image(png, _, _):
            "image:" + Self.sha256Hex(png)
        case let .files(urls):
            Self.sha256Hex(Data(("files:" + urls.map(\.path).joined(separator: "\n")).utf8))
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
