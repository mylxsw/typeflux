import SwiftUI

extension AskKeywordKind {
    /// The tile colour that tells the kinds apart in the list.
    var tint: Color {
        switch self {
        case .translate: TypefluxColor.accent.color
        case .prompt: Color.purple
        case .web: TypefluxColor.success.color
        case .files: Color.teal
        case .tabs: Color.orange
        case .bookmarks: Color.blue
        case .chat: Color.blue
        case .prefix: Color.indigo
        case .setting: Color.gray
        case .history: Color.blue
        case .clip: Color.teal
        case .emoji: Color.orange
        case .kill: Color.red
        case .system: Color.gray
        case .workflow: Color.orange
        }
    }
}
