import Foundation

/// The panel separates copied items, voice results and permanent snippets.
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case voice
    case snippet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("clipboard.tab.clipboard")
        case .voice: L("clipboard.tab.transcription")
        case .snippet: L("clipboard.tab.snippet")
        }
    }

    var searchPlaceholderKey: String {
        switch self {
        case .all: "clipboard.search.placeholder"
        case .voice: "clipboard.transcription.search"
        case .snippet: "clipboard.snippet.search"
        }
    }

    var emptyKey: String {
        switch self {
        case .all: "clipboard.empty"
        case .voice: "clipboard.transcription.empty"
        case .snippet: "clipboard.snippet.empty"
        }
    }
}
