import SwiftUI

/// Native List draws selection and supports keyboard navigation.
struct AskWordBookRow: View {
    var entry: AskWordBookEntry
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.headword).font(.headline).foregroundStyle(TypefluxColor.label.color).lineLimit(1)
                Text(entry.lookup.summary).font(.footnote).lineLimit(1)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            Spacer(minLength: 4)
            VStack(spacing: 0) {
                if entry.isStarred {
                    Image(systemName: "star.fill").foregroundStyle(TypefluxColor.accent.color)
                        .accessibilityLabel(L("ask.wordBook.starredLabel"))
                }
                if entry.lookupCount > 1 {
                    Text("×\(entry.lookupCount)").font(.caption).monospacedDigit()
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
        }
        .modifier(TypefluxLibraryRow(selected: selected))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.wordBook.row")
    }
}
