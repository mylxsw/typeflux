import Foundation

/// The panel separates temporary clipboard history from permanent snippets.
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case snippet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("clipboard.tab.clipboard")
        case .snippet: L("clipboard.tab.snippet")
        }
    }
}
