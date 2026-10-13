import SwiftUI

struct PasswordChangeSuccessSheet: View {
    let onRelogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: TypefluxSpacing.small.value(for: .classic)) {
                Text(L("auth.account.passwordChangeSuccessTitle"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(TypefluxColor.label.color)

                Text(L("auth.account.passwordChanged"))
                    .font(.body)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                TypefluxButton(L("auth.account.relogin"), kind: .primary, action: onRelogin)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
