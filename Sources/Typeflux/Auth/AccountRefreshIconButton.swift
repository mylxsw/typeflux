import SwiftUI

struct AccountRefreshIconButton: View {
    let helpText: String
    var isDisabled = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        TypefluxButton(kind: .borderless, action: action) {
            if isLoading {
                TypefluxProgress(helpText).labelsHidden()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .accessibilityLabel(helpText).typefluxHelp(helpText)
        .disabled(isDisabled || isLoading)
    }
}
