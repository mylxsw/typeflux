import SwiftUI

/// A compact menu for all plugin kinds, each with its count.
struct AskKeywordFilterBar: View {
    @Binding var selection: AskKeywordKind?
    let counts: [AskKeywordKind?: Int]

    private var options: [(AskKeywordKind?, String)] {
        [(nil, L("ask.settings.keywords.filter.all"))] + AskKeywordKind.editableKinds.map { ($0, $0.title) }
    }

    var body: some View {
        TypefluxPopup(title: options.first { $0.0 == selection }?.1 ?? L("ask.settings.keywords.filter.all"),
                      options: options.map { (label: "\($0.1) · \(counts[$0.0] ?? 0)", value: $0.0) },
                      selection: $selection)
            .accessibilityIdentifier("ask.settings.keywords.filter")
    }
}
