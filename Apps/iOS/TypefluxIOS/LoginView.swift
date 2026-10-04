import SwiftUI

struct LoginView: View {
    @Bindable var store: ChatStore
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        ChatOrb(size: 88)
                        Text("Ask anything").font(.largeTitle.bold())
                        Text("Your Typeflux conversations, wherever an idea finds you.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .padding(.top, 52)
                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("login.email")
                        Divider()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("login.password")
                    }
                    .padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    if let error = store.errorMessage {
                        Text(NSLocalizedString(error, comment: "Sign-in error")).font(.callout).foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                    }
                    Button {
                        Task {
                            await store.login(email: email, password: password)
                            password = ""
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Sign in").fontWeight(.semibold)
                            }
                            Spacer()
                        }.padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading || email.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || password.isEmpty)
                    .accessibilityIdentifier("login.submit")
                    Text("Sign in with an existing Typeflux email and password account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(28).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(ChatTheme.background)
            .navigationTitle("Typeflux").navigationBarTitleDisplayMode(.inline)
        }
    }
}
