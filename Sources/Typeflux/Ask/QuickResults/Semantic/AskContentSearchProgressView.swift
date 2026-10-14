import SwiftUI

/// A quiet, non-selectable list row; late content results remain discoverable without blocking names.
struct AskContentSearchProgressView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 14, height: 14)
            Text(L("semantic.searching")).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 10).frame(height: 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("semantic.searching")
    }
}
