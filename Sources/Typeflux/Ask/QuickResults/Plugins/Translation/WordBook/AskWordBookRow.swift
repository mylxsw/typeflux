import SwiftUI

/// Native List draws selection and supports keyboard navigation.
struct AskWordBookRow: View {
    var entry: AskWordBookEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.headword).font(.headline).lineLimit(1)
                Text(entry.lookup.summary).font(.callout).lineLimit(2)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
            Spacer(minLength: 4)
            VStack(spacing: 4) {
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.wordBook.row")
    }
}
