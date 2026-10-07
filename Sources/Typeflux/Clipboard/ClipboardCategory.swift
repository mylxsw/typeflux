import Foundation

/// The panel's filter tabs.
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("clipboard.tab.all")
        case .text: L("clipboard.tab.text")
        case .image: L("clipboard.tab.image")
        case .file: L("clipboard.tab.file")
        case .voice: L("clipboard.tab.voice")
        }
    }
}
