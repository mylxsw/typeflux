import SwiftUI

/// macOS 13 counterpart of ContentUnavailableView; also rendered directly by compatibility tests.
struct TypefluxEmptyStateFallback<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .accessibilityHidden(true)
            Text(title).font(.title3).fontWeight(.semibold).multilineTextAlignment(.center)
            Text(description).font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .multilineTextAlignment(.center)
            actions
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
