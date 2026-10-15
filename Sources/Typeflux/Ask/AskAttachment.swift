import AppKit
import Foundation
import ImageIO
import TypefluxMediaProtocol
import UniformTypeIdentifiers

/// A file, image or folder the user added to a question. Images and text are
/// prepared on this Mac before sending; a folder sends only its path and is
/// opened to the `files` tool for the conversation.
struct AskAttachment: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case image, file, folder }

    var id: String = UUID().uuidString
    var kind: Kind
    var name: String
    /// Size of the original file in bytes.
    var byteSize: Int? = nil
    /// JPEG data URL for an image.
    var image: String? = nil
    /// Text extracted from a text file or PDF.
    var text: String? = nil
    /// The text was cut at `AskAttachmentLimits.maximumTextCharacters`.
    var truncated: Bool? = nil
    /// Pages of a PDF.
    var pages: Int? = nil
    /// Absolute path of a folder.
    var path: String? = nil

    /// Bytes this attachment adds to a request.
    var payloadBytes: Int { (image?.utf8.count ?? 0) + (text?.utf8.count ?? 0) + (path?.utf8.count ?? 0) }
}

enum AskAttachmentLimits {
    /// Files and images in one message; folders are counted separately.
    static let maximumItems = 10
    /// Images in one message, including the screenshot.
    static let maximumImages = 8
    static let maximumFolders = 5
    /// Image data URLs and extracted text together, per message. The server
    /// accepts the same amount; it keeps a request well under its body limit.
    static let maximumPayloadBytes = 4_000_000
    static let maximumImageDataURLBytes = MediaLimits.imageBytes
    static let maximumTextFileBytes = 5_000_000
    static let maximumPDFBytes = MediaLimits.inputBytes
    static let maximumImageFileBytes = MediaLimits.inputBytes
    static let maximumTextCharacters = MediaLimits.textCharacters
    static let imageLongEdge = MediaLimits.imageLongEdge
    /// Pages of a PDF without a text layer sent as images.
    static let maximumScannedPages = MediaLimits.scannedPages
}

/// Why an attachment was not added. The message names the file.
enum AskAttachmentError: Error, Equatable, Sendable {
    case unsupported(String)
    case tooLarge(String)
    case unreadable(String)
    case tooMany
    case tooManyImages
    case tooManyFolders
    case payload
    case busy

    var message: String {
        switch self {
        case let .unsupported(name): return L("ask.attach.unsupported", name)
        case let .tooLarge(name): return L("ask.attach.tooLarge", name)
        case let .unreadable(name): return L("ask.attach.unreadable", name)
        case .tooMany: return L("ask.attach.tooMany", AskAttachmentLimits.maximumItems)
        case .tooManyImages: return L("ask.attach.tooManyImages", AskAttachmentLimits.maximumImages)
        case .tooManyFolders: return L("ask.attach.tooManyFolders", AskAttachmentLimits.maximumFolders)
        case .payload: return L("ask.attach.payload")
        case .busy: return L("ask.attach.busy")
        }
    }
}

/// Something dropped, pasted or picked that can become attachments.
enum AskAttachmentSource: Equatable, @unchecked Sendable {
    case file(URL)
    /// Image data without a file, such as a copied screenshot.
    case image(Data, name: String)

    var name: String {
        switch self {
        case let .file(url): return url.lastPathComponent
        case let .image(_, name): return name
        }
    }

    /// File URLs come first: Finder puts both the files and their names on the pasteboard.
    /// Image data counts only without text, because apps such as Notes or Word put a
    /// picture of copied text next to the text itself, and that must paste as text.
    /// A drag is deliberate, so `textWins` is false there: an image dragged out of
    /// a browser also carries its address as text, and must still attach.
    static func read(from pasteboard: NSPasteboard, textWins: Bool = true) -> [AskAttachmentSource] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map { .file($0) } }
        guard !textWins || pasteboard.availableType(from: [.string]) == nil else { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [.image(data, name: L("ask.attach.pastedImage"))] }
        }
        return []
    }

    /// Whether a paste or drop should attach rather than insert text.
    static func canRead(from pasteboard: NSPasteboard, textWins: Bool = true) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        guard !textWins || pasteboard.availableType(from: [.string]) == nil else { return false }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }
}

/// Turns sources into attachments off the main actor. Images are re-encoded as
/// JPEG without their metadata, so location data never leaves the Mac.
enum AskAttachmentLoader {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml", "log", "html", "htm", "css",
        "swift", "go", "py", "rb", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs",
        "js", "jsx", "ts", "tsx", "vue", "php", "sh", "zsh", "bash", "sql", "toml", "ini", "conf", "env", "proto",
        "gradle", "dart", "lua", "r", "scala", "tex", "srt", "vtt", "rtf"
    ]

    /// Loads one source. A PDF without text becomes one image per page.
    static func load(_ source: AskAttachmentSource, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [AskAttachment] {
        switch source {
        case let .image(data, name):
            return [try image(data: data, name: name, byteSize: data.count, isCancelled: isCancelled)]
        case let .file(url):
            return try file(url, isCancelled: isCancelled)
        }
    }

    static func file(_ url: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [AskAttachment] {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true {
            return [AskAttachment(kind: .folder, name: name, path: url.standardizedFileURL.path)]
        }
        let size = values?.fileSize ?? 0
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let ext = url.pathExtension.lowercased()
        if type?.conforms(to: .pdf) == true || ext == "pdf" {
            guard size <= AskAttachmentLimits.maximumPDFBytes else { throw AskAttachmentError.tooLarge(name) }
            return try pdf(url, name: name, byteSize: size, isCancelled: isCancelled)
        }
        if type?.conforms(to: .image) == true {
            guard size <= AskAttachmentLimits.maximumImageFileBytes else { throw AskAttachmentError.tooLarge(name) }
            return try media(.image, source: .file(url), name: name, byteSize: size, isCancelled: isCancelled)
        }
        if textExtensions.contains(ext) || type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true {
            guard size <= AskAttachmentLimits.maximumTextFileBytes else { throw AskAttachmentError.tooLarge(name) }
            guard let data = try? Data(contentsOf: url) else { throw AskAttachmentError.unreadable(name) }
            guard let text = decodeText(data) else { throw AskAttachmentError.unreadable(name) }
            return [textAttachment(text, name: name, byteSize: size)]
        }
        throw AskAttachmentError.unsupported(name)
    }

    static func textAttachment(_ text: String, name: String, byteSize: Int, pages: Int? = nil) -> AskAttachment {
        let limit = AskAttachmentLimits.maximumTextCharacters
        let truncated = text.count > limit
        return AskAttachment(kind: .file, name: name, byteSize: byteSize,
                             text: truncated ? String(text.prefix(limit)) : text,
                             truncated: truncated ? true : nil, pages: pages)
    }

    /// UTF-8 first, then the encodings common for Chinese text. Binary data is rejected.
    static func decodeText(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding in [gb18030, .utf16] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    static func pdf(_ url: URL, name: String, byteSize: Int,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [AskAttachment] {
        try media(.pdf, source: .file(url), name: name, byteSize: byteSize, isCancelled: isCancelled)
    }

    static func image(data: Data, name: String, byteSize: Int,
                      isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> AskAttachment {
        try media(.image, source: .data(data), name: name, byteSize: byteSize, isCancelled: isCancelled)[0]
    }

    private static func media(_ operation: MediaRequest.Operation, source: MediaWorker.Input,
                              name: String, byteSize: Int, isCancelled: @escaping @Sendable () -> Bool) throws -> [AskAttachment] {
        do {
            return try MediaWorker.shared.decode(operation, input: source, isCancelled: isCancelled).items.map { item in
                AskAttachment(kind: item.image == nil ? .file : .image,
                              name: item.page.map { L("ask.attach.pdfPage", name, $0) } ?? name,
                              byteSize: byteSize, image: item.image, text: item.text,
                              truncated: item.truncated == true ? true : nil, pages: item.pages)
            }
        } catch MediaFailure.tooLarge { throw AskAttachmentError.tooLarge(name) }
        catch { throw AskAttachmentError.unreadable(name) }
    }

    /// Flattens transparency onto white and encodes JPEG without metadata,
    /// shrinking until the data URL fits the per-image limit.
    static func jpegDataURL(_ image: CGImage, limit: Int = AskAttachmentLimits.maximumImageDataURLBytes) -> String? {
        var current = image
        for quality in [0.82, 0.7, 0.6, 0.5] {
            for _ in 0 ..< 2 {
                if let data = jpeg(current, quality: quality) {
                    let url = "data:image/jpeg;base64," + data.base64EncodedString()
                    if url.utf8.count <= limit { return url }
                }
                guard let smaller = scaled(current, by: 0.75) else { return nil }
                current = smaller
            }
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        guard let flat = scaled(image, by: 1) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Redraws into an opaque RGB context, which also drops alpha and colour-space quirks.
    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension AskDraft {
    var attachedImageCount: Int { (attachments ?? []).filter { $0.kind == .image }.count }

    /// Adds loaded attachments in order until a limit is reached; the first
    /// refusal is returned so the composer can say why.
    @discardableResult
    mutating func append(_ items: [AskAttachment]) -> AskAttachmentError? {
        var current = attachments ?? []
        var refusal: AskAttachmentError?
        for item in items {
            // The same folder twice is already granted; nothing to report.
            if item.kind == .folder, current.contains(where: { $0.kind == .folder && $0.path == item.path }) { continue }
            if let reason = Self.refusal(for: item, in: current, screenshot: includeScreenshot && screenshot != nil) {
                refusal = refusal ?? reason
                continue
            }
            current.append(item)
        }
        attachments = current.isEmpty ? nil : current
        return refusal
    }

    static func refusal(for item: AskAttachment, in current: [AskAttachment], screenshot: Bool) -> AskAttachmentError? {
        switch item.kind {
        case .folder:
            if current.filter({ $0.kind == .folder }).count >= AskAttachmentLimits.maximumFolders { return .tooManyFolders }
        case .image:
            let images = current.filter { $0.kind == .image }.count + (screenshot ? 1 : 0)
            if images >= AskAttachmentLimits.maximumImages { return .tooManyImages }
            fallthrough
        case .file:
            if current.filter({ $0.kind != .folder }).count >= AskAttachmentLimits.maximumItems { return .tooMany }
        }
        let used = current.reduce(0) { $0 + $1.payloadBytes }
        if used + item.payloadBytes > AskAttachmentLimits.maximumPayloadBytes { return .payload }
        return nil
    }

    mutating func removeAttachment(_ id: String) {
        attachments?.removeAll { $0.id == id }
        if attachments?.isEmpty == true { attachments = nil }
    }
}
