import SwiftUI

/// A keyword is content, so it uses semantic monospaced text.
struct AskKeywordLabel: View {
    let keyword: String
    var isDefault = false

    var body: some View {
        Text(keyword).font(.body.monospaced())
            .foregroundStyle(isDefault ? TypefluxColor.accent.color : TypefluxColor.secondaryLabel.color)
            .lineLimit(1).help(keyword)
    }
}
