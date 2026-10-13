import SwiftUI

struct LoginTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    var isSecure: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        Group {
            if isSecure {
                TypefluxSecureField(placeholder, text: $text)
            } else {
                TypefluxTextField(placeholder, text: $text)
            }
        }
        .controlSize(.large)
        .disabled(isDisabled)
    }
}
