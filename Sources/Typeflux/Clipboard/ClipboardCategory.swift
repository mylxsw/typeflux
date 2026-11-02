import Foundation

/// The panel separates copied items, permanent snippets, voice results and screenshots.
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case snippet
    case voice
    case screenshot

    var id: String { rawValue }

    var title: String { L("clipboard.tab.\(rawValue).compact") }

    var fullTitle: String {
        switch self {
        case .all: L("clipboard.tab.clipboard")
        case .voice: L("clipboard.tab.transcription")
        case .snippet: L("clipboard.tab.snippet")
        case .screenshot: L("clipboard.tab.screenshot")
        }
    }

    var searchPlaceholderKey: String {
        switch self {
        case .all: "clipboard.search.placeholder"
        case .voice: "clipboard.transcription.search"
        case .snippet: "clipboard.snippet.search"
        case .screenshot: "clipboard.screenshot.search"
        }
    }

    var emptyKey: String {
        switch self {
        case .all: "clipboard.empty"
        case .voice: "clipboard.transcription.empty"
        case .snippet: "clipboard.snippet.empty"
        case .screenshot: "clipboard.screenshot.empty"
        }
    }
}
