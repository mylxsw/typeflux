import SwiftUI

/// Native menu items keep keyboard navigation and system highlights.
struct AskKeywordMenuItem: View {
    let kind: AskKeywordKind
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: kind.symbol) }
            .help(kind.hint).accessibilityIdentifier("ask.settings.keywords.add." + kind.rawValue)
    }
}
