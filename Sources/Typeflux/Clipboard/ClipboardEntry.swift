import Foundation

/// One row of the clipboard panel: a voice history record or a captured clipboard item.
struct ClipboardEntry: Identifiable, Equatable {
    enum Origin: Equatable {
        case voice(UUID)
        case clipboard(UUID)
    }

    let origin: Origin
    let kind: ClipboardEntryKind
    let date: Date
    /// Text pasted for textual entries.
    let text: String?
    let filePaths: [String]
    let imagePath: String?
    let imagePixelSize: CGSize?
    let byteSize: Int64
    /// The app that was frontmost when the content was copied; `nil` for older records and voice results.
    let sourceBundleID: String?
    let sourceAppName: String?
    let isPinned: Bool

    var id: String {
        switch origin {
        case let .voice(id): "voice-\(id.uuidString)"
        case let .clipboard(id): "clipboard-\(id.uuidString)"
        }
    }

    var fileURLs: [URL] {
        filePaths.map { URL(fileURLWithPath: $0) }
    }

    /// Files the entry pastes or previews: the copied files, or the stored image.
    var contentURLs: [URL] {
        if let imagePath { return [URL(fileURLWithPath: imagePath)] }
        return fileURLs
    }

    /// Whether the row shows the content itself (thumbnails, a video frame, a waveform) instead of a title.
    var hasInlineMedia: Bool {
        switch kind {
        case .image, .images, .video, .audio: true
        default: false
        }
    }

    /// The name shown next to an inline preview: the file name or image count; `nil` for an image
    /// that only lives in the store (a screenshot), whose preview needs no caption.
    var mediaCaption: String? {
        if kind == .images, filePaths.count > 1 { return title }
        return filePaths.first.map { ($0 as NSString).lastPathComponent }
    }

    /// The single-line title: the text itself, the file name, or a count.
    var title: String {
        if let text { return text }
        switch kind {
        case .images where filePaths.count > 1:
            return L("clipboard.entry.imageCount", filePaths.count)
        case .files:
            return L("clipboard.entry.fileCount", filePaths.count)
        default:
            if let first = filePaths.first { return (first as NSString).lastPathComponent }
            return L("clipboard.entry.image")
        }
    }
}
