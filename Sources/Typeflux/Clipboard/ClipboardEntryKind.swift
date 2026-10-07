import Foundation

/// What a clipboard panel row shows; derived from the payload and its file types.
enum ClipboardEntryKind: Equatable {
    case voice
    case text
    case link
    case code
    case image
    case images
    case pdf
    case document
    case video
    case audio
    case files

    var category: ClipboardCategory {
        switch self {
        case .voice: .voice
        case .text, .link, .code: .text
        case .image, .images: .image
        case .pdf, .document, .video, .audio, .files: .file
        }
    }

    /// Text-like entries paste through the text injector; the rest paste pasteboard objects.
    var isTextual: Bool {
        category == .voice || category == .text
    }
}
