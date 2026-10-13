import SwiftUI

struct OnboardingActionButton: View {
    let title: String
    let systemImage: String?
    var kind: TypefluxButtonKind = .regular
    var isDisabled = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        TypefluxButton(kind: kind, action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
        }
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(title)
    }
}
