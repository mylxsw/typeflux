import Foundation
import TypefluxUI

/// Clipboard content modes keep permanent snippets separate from temporary history.
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case link
    case snippet

    var id: String { rawValue }
    var title: String { L("clipboard.tab." + rawValue) }

    var spotlightMode: TypefluxSpotlightMode {
        TypefluxSpotlightMode(id: id, title: title, systemImage: systemImage)
    }

    private var systemImage: String {
        switch self {
        case .all: "clipboard"
        case .text: "doc.text"
        case .image: "photo"
        case .link: "link"
        case .snippet: "scissors"
        }
    }

    func includes(_ entry: ClipboardEntry) -> Bool {
        guard (self == .snippet) == (entry.snippet != nil) else { return false }
        switch self {
        case .all, .snippet: return true
        case .text: return entry.kind.isTextual && entry.kind != .link
        case .image: return entry.kind == .image || entry.kind == .images
        case .link: return entry.kind == .link
        }
    }
}
