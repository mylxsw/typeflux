import Foundation

/// What a clipboard panel row shows; derived from the payload and its file types.
enum ClipboardEntryKind: Equatable, Sendable {
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

    /// Text-like entries paste through the text injector; the rest paste pasteboard objects.
    var isTextual: Bool {
        switch self {
        case .voice, .text, .link, .code: true
        default: false
        }
    }
}
