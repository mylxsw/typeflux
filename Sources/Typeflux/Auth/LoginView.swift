import AuthenticationServices
import SwiftUI

enum LoginGooglePreflight {
    static func errorMessage(
        for step: LoginView.Step,
        hasAcceptedPolicies: Bool,
        localization: AppLocalization = .shared
    ) -> String? {
        guard step == .enterEmail, !hasAcceptedPolicies else {
            return nil
        }

        return localization.string("auth.error.policyAgreementRequired")
    }
}

enum SocialLoginProvider: Hashable {
    case google
    case github
    case apple
}

enum SocialLoginLayout {
    static func enabledProviders(
        googleClientID: String,
        githubClientID: String
    ) -> [SocialLoginProvider] {
        var providers: [SocialLoginProvider] = []

        providers.append(.apple)
        if !googleClientID.isEmpty {
            providers.append(.google)
        }
        if !githubClientID.isEmpty {
            providers.append(.github)
        }

        return providers
    }
}

struct LoginView: View {
    enum PresentationStyle {
        case card
        case plain
    }

    enum Step {
        case enterEmail
        case login
        case register
        case activate
        case forgotPassword
        case resetPassword
    }

    @StateObject private var authState = AuthState.shared
    @State private var step: Step = .enterEmail
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var name = ""
    @State private var activationCode = ""
    @State private var resetCode = ""
    @State private var resetPassword = ""
    @State private var resetPasswordConfirmation = ""
    @State private var hasAcceptedPolicies = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var previousStepBeforeActivate: Step = .register
    @State private var resendCooldownRemaining = 0
    @State private var isGoogleLoading = false
    @State private var isGitHubLoading = false
    @State private var isAppleLoading = false
    private let googleClientID = AppServerConfiguration.googleOAuthClientID
    private let googleClientSecret = AppServerConfiguration.googleOAuthClientSecret
    private let githubClientID = AppServerConfiguration.githubOAuthClientID
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.colorScheme) private var colorScheme

    private let privacyURL = URL(string: "https://typeflux.gulu.ai/privacy")!
    private let termsURL = URL(string: "https://typeflux.gulu.ai/terms")!
    private let resendTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    let presentationStyle: PresentationStyle
    let onDismiss: () -> Void

    init(
        presentationStyle: PresentationStyle = .card,
        onDismiss: @escaping () -> Void
    ) {
        self.presentationStyle = presentationStyle
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            switch presentationStyle {
            case .card:
                cardBody
            case .plain:
                plainBody
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .onReceive(resendTimer) { _ in
            guard resendCooldownRemaining > 0 else { return }
            resendCooldownRemaining -= 1
        }
    }

    private var cardBody: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                plainHeader
                    .padding(.bottom, 10)

                formContent

                if showsPolicyAgreement {
                    policyAgreementSection
                }

                if step != .enterEmail {
                    Divider()
                        .overlay(loginCardDivider)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            goBack()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: StudioTheme.Typography.caption, weight: .medium))
                            Text(L("auth.login.back"))
                                .font(.studioBody(StudioTheme.Typography.body))
                        }
                        .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(StudioTheme.windowBackground)
    }

    private var plainBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                plainHeader
                    .padding(.bottom, 10)

                formContent

                if showsPolicyAgreement {
                    policyAgreementSection
                }

                if step != .enterEmail {
                    Divider()
                        .overlay(loginCardDivider)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            goBack()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: StudioTheme.Typography.caption, weight: .medium))
                            Text(L("auth.login.back"))
                                .font(.studioBody(StudioTheme.Typography.body))
                        }
                        .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(contentPadding)
            .background(containerBackground)
            .overlay(containerBorder)
            .shadow(color: containerShadow, radius: containerShadowRadius, x: 0, y: containerShadowYOffset)
        }
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var formContent: some View {
        VStack(spacing: 16) {
            switch step {
            case .enterEmail:
                enterEmailForm
            case .login:
                loginForm
            case .register:
                registerForm
            case .activate:
                activateForm
            case .forgotPassword:
                forgotPasswordForm
            case .resetPassword:
                resetPasswordForm
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(maxWidth: .infinity, alignment: formContentAlignment)
                    .multilineTextAlignment(presentationStyle == .card ? .center : .leading)
                    .transition(.opacity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.danger)
                    .frame(maxWidth: .infinity, alignment: formContentAlignment)
                    .multilineTextAlignment(presentationStyle == .card ? .center : .leading)
                    .transition(.opacity)
            }
        }
    }

    private var plainHeader: some View {
        VStack(spacing: 10) {
            if step == .enterEmail {
                TypefluxLogoBadge(
                    size: 84,
                    symbolSize: 40,
                    backgroundShape: .circle,
                    showsBorder: true,
                )
                .padding(.bottom, 10)

                Text("Typeflux Cloud")
                    .font(.studioBody(11, weight: .semibold))
                    .tracking(2.2)
                    .textCase(.uppercase)
                    .foregroundStyle(brandEyebrowColor)
            }

            Text(plainHeaderTitle)
                .font(.studioDisplay(30, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
                .multilineTextAlignment(.center)

            if let subtitle = plainHeaderSubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.studioBody(13))
                    .foregroundStyle(headerSubtitleColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var enterEmailForm: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
            if !socialLoginProviders.isEmpty {
                socialLoginButtonsRow
                orDivider
            }

            LoginTextField(
                placeholder: L("auth.field.email"),
                text: $email,
                icon: "envelope",
            )

            if step == .enterEmail {
                Text(plainEmailHelperText)
                    .font(.studioBody(12))
                    .foregroundStyle(helperTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            loginButton(title: L("auth.login.continue"), action: checkEmail)
        }
    }

    private var socialLoginProviders: [SocialLoginProvider] {
        SocialLoginLayout.enabledProviders(
            googleClientID: googleClientID,
            githubClientID: githubClientID
        )
    }

    private var socialLoginButtonsRow: some View {
        HStack(spacing: StudioTheme.Spacing.medium) {
            ForEach(socialLoginProviders, id: \.self) { provider in
                socialLoginButton(for: provider)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func socialLoginButton(for provider: SocialLoginProvider) -> some View {
        Button(action: action(for: provider)) {
            ZStack {
                if isLoadingProvider(provider) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    socialLoginIcon(for: provider)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: socialButtonSize, height: socialButtonSize)
            .foregroundStyle(socialButtonTextColor(for: provider))
            .background(
                Circle()
                    .fill(socialButtonFillColor(for: provider))
            )
            .overlay(
                Circle()
                    .stroke(socialButtonStrokeColor(for: provider), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isGoogleLoading || isGitHubLoading || isAppleLoading)
        .help(socialLoginAccessibilityLabel(for: provider))
        .accessibilityLabel(socialLoginAccessibilityLabel(for: provider))
    }

    @ViewBuilder
    private func socialLoginIcon(for provider: SocialLoginProvider) -> some View {
        switch provider {
        case .google:
            GoogleLogoMark()
        case .github:
            GitHubLogoMark()
        case .apple:
            AppleLogoMark()
        }
    }

    private func action(for provider: SocialLoginProvider) -> () -> Void {
        switch provider {
        case .google:
            performGoogleLogin
        case .github:
            performGitHubLogin
        case .apple:
            performAppleLogin
        }
    }

    private func isLoadingProvider(_ provider: SocialLoginProvider) -> Bool {
        switch provider {
        case .google:
            isGoogleLoading
        case .github:
            isGitHubLoading
        case .apple:
            isAppleLoading
        }
    }

    private func socialLoginAccessibilityLabel(for provider: SocialLoginProvider) -> String {
        switch provider {
        case .google:
            L("auth.login.continueWithGoogle")
        case .github:
            L("auth.login.continueWithGitHub")
        case .apple:
            L("auth.login.continueWithApple")
        }
    }

    private var socialButtonSize: CGFloat {
        52
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(orDividerColor)
                .frame(height: 1)
            Text(L("auth.login.orDivider"))
                .font(.studioBody(12))
                .foregroundStyle(StudioTheme.textTertiary)
                .fixedSize()
            Rectangle()
                .fill(orDividerColor)
                .frame(height: 1)
        }
    }

    private var orDividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    private func socialButtonFillColor(for provider: SocialLoginProvider) -> Color {
        switch provider {
        case .google:
            return colorScheme == .dark ? Color.white.opacity(0.07) : Color.white
        case .github:
            return colorScheme == .dark
                ? Color(red: 0.14, green: 0.14, blue: 0.14)
                : Color(red: 0.13, green: 0.13, blue: 0.13)
        case .apple:
            return colorScheme == .dark ? Color.white : Color.black
        }
    }

    private func socialButtonTextColor(for provider: SocialLoginProvider) -> Color {
        switch provider {
        case .google:
            return colorScheme == .dark ? StudioTheme.textPrimary : Color.black.opacity(0.80)
        case .github:
            return Color.white
        case .apple:
            return colorScheme == .dark ? Color.black : Color.white
        }
    }

    private func socialButtonStrokeColor(for provider: SocialLoginProvider) -> Color {
        switch provider {
        case .google:
            return colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
        case .github:
            return colorScheme == .dark ? Color.white.opacity(0.10) : Color.clear
        case .apple:
            return Color.clear
        }
    }

    private var loginForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            LoginTextField(
                placeholder: L("auth.field.email"),
                text: .constant(email),
                icon: "envelope",
                isDisabled: true,
            )

            LoginTextField(
                placeholder: L("auth.field.password"),
                text: $password,
                icon: "lock",
                isSecure: true,
            )

            loginButton(title: L("auth.login.signIn"), action: performLogin)

            Button(action: openForgotPassword) {
                Text(L("auth.login.forgotPassword"))
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private var registerForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            LoginTextField(
                placeholder: L("auth.field.email"),
                text: .constant(email),
                icon: "envelope",
                isDisabled: true,
            )

            LoginTextField(
                placeholder: L("auth.field.name"),
                text: $name,
                icon: "person",
            )

            LoginTextField(
                placeholder: L("auth.field.password"),
                text: $password,
                icon: "lock",
                isSecure: true,
            )

            LoginTextField(
                placeholder: L("auth.field.confirmPassword"),
                text: $confirmPassword,
                icon: "lock.rotation",
                isSecure: true,
            )

            loginButton(title: L("auth.login.createAccount"), action: performRegister)
        }
    }

    private var activateForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            Text(L("auth.login.activateHint", email))
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center)

            LoginTextField(
                placeholder: L("auth.field.activationCode"),
                text: $activationCode,
                icon: "number",
            )

            loginButton(title: L("auth.login.activate"), action: performActivate)

            Button(action: resendActivationCode) {
                Text(resendActivationButtonTitle)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(resendCooldownRemaining > 0 ? StudioTheme.textTertiary : StudioTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || resendCooldownRemaining > 0)
        }
    }

    private var forgotPasswordForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            Text(L("auth.login.forgotPasswordHint", email))
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center)

            LoginTextField(
                placeholder: L("auth.field.email"),
                text: .constant(email),
                icon: "envelope",
                isDisabled: true,
            )

            loginButton(title: L("auth.login.sendResetCode"), action: performForgotPassword)

            Button {
                clearMessages()
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .resetPassword
                }
            } label: {
                Text(L("auth.login.alreadyHaveResetCode"))
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
        }
    }

    private var resetPasswordForm: some View {
        VStack(spacing: StudioTheme.Spacing.medium) {
            LoginTextField(
                placeholder: L("auth.field.email"),
                text: .constant(email),
                icon: "envelope",
                isDisabled: true,
            )

            LoginTextField(
                placeholder: L("auth.field.resetCode"),
                text: $resetCode,
                icon: "key",
            )

            LoginTextField(
                placeholder: L("auth.field.newPassword"),
                text: $resetPassword,
                icon: "lock",
                isSecure: true,
            )

            LoginTextField(
                placeholder: L("auth.field.confirmNewPassword"),
                text: $resetPasswordConfirmation,
                icon: "lock.rotation",
                isSecure: true,
            )

            loginButton(title: L("auth.login.resetPassword"), action: performResetPassword)
        }
    }

    private func loginButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                } else {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundStyle(buttonTextColor)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                    .fill(buttonFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                    .stroke(buttonStrokeColor, lineWidth: buttonStrokeWidth)
            )
        }
        .buttonStyle(.plain)
        .opacity(isButtonEnabled ? 1 : disabledButtonOpacity)
        .disabled(!isButtonEnabled)
    }

    @ViewBuilder
    private var containerBackground: some View {
        switch presentationStyle {
        case .card:
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(loginCardSurface)
        case .plain:
            Color.clear
        }
    }

    @ViewBuilder
    private var containerBorder: some View {
        switch presentationStyle {
        case .card:
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(loginCardStroke, lineWidth: 1)
        case .plain:
            EmptyView()
        }
    }

    private var loginCardDivider: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : StudioTheme.border.opacity(0.9)
    }

    private var contentPadding: CGFloat {
        switch presentationStyle {
        case .card:
            24
        case .plain:
            0
        }
    }

    private var maxWidth: CGFloat {
        switch presentationStyle {
        case .card, .plain:
            460
        }
    }

    private var formContentAlignment: Alignment {
        presentationStyle == .card ? .center : .leading
    }

    private var containerShadow: Color {
        switch presentationStyle {
        case .card:
            loginCardShadow
        case .plain:
            .clear
        }
    }

    private var containerShadowRadius: CGFloat {
        presentationStyle == .card ? 28 : 0
    }

    private var containerShadowYOffset: CGFloat {
        presentationStyle == .card ? 18 : 0
    }

    private var loginCardSurface: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : StudioTheme.surface
    }

    private var loginCardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : StudioTheme.border
    }

    private var loginCardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.08)
    }

    private var showsPolicyAgreement: Bool {
        step == .enterEmail
    }

    private var plainEmailHelperText: String {
        switch localization.language {
        case .simplifiedChinese:
            "未注册的账号验证成功后将自动注册"
        case .traditionalChinese:
            "未註冊的帳號驗證成功後將自動註冊"
        case .japanese:
            "未登録のアカウントは認証後に自動作成されます。"
        case .korean:
            "등록되지 않은 계정은 인증이 완료되면 자동으로 생성됩니다."
        case .english:
            "Unregistered accounts will be created automatically after verification."
        }
    }

    private var isButtonEnabled: Bool {
        !isLoading && (!showsPolicyAgreement || hasAcceptedPolicies)
    }

    private var buttonFillColor: Color {
        if isButtonEnabled {
            return StudioTheme.accent
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 0.90, green: 0.91, blue: 0.94)
    }

    private var buttonTextColor: Color {
        if isButtonEnabled {
            return .white
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.6)
            : Color.black.opacity(0.48)
    }

    private var buttonStrokeColor: Color {
        if isButtonEnabled {
            return .clear
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    private var buttonStrokeWidth: CGFloat {
        isButtonEnabled ? 0 : 1
    }

    private var disabledButtonOpacity: Double {
        colorScheme == .dark ? 0.62 : 1
    }

    private var policyAgreementSection: some View {
        HStack {
            Spacer(minLength: 0)
            Toggle(isOn: $hasAcceptedPolicies) {
                agreementText
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .tint(StudioTheme.accent)
            .foregroundStyle(policyTextColor)
            .font(.studioBody(12))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var agreementText: some View {
        HStack(spacing: 4) {
            Text(agreementLeadInText)
                .foregroundStyle(policyTextColor)
            Link(agreementTermsTitle, destination: termsURL)
                .foregroundStyle(StudioTheme.accent)
            Text(agreementSeparatorText)
                .foregroundStyle(policyTextColor)
            Link(agreementPrivacyTitle, destination: privacyURL)
                .foregroundStyle(StudioTheme.accent)
        }
        .font(.studioBody(12))
        .multilineTextAlignment(.center)
    }

    private var agreementLeadInText: String {
        switch localization.language {
        case .simplifiedChinese:
            "已阅读并同意"
        case .traditionalChinese:
            "已閱讀並同意"
        case .japanese:
            "以下に同意します:"
        case .korean:
            "다음에 동의합니다:"
        case .english:
            "I have read and agree to the"
        }
    }

    private var plainHeaderTitle: String {
        switch step {
        case .enterEmail, .login:
            switch localization.language {
            case .simplifiedChinese:
                "欢迎回来"
            case .traditionalChinese:
                "歡迎回來"
            case .japanese:
                "お帰りなさい"
            case .korean:
                "다시 오신 것을 환영합니다"
            case .english:
                "Welcome Back"
            }
        case .register:
            switch localization.language {
            case .simplifiedChinese:
                "创建新账号"
            case .traditionalChinese:
                "建立新帳號"
            case .japanese:
                "新しいアカウントを作成"
            case .korean:
                "새 계정 만들기"
            case .english:
                "Create Account"
            }
        case .activate:
            L("auth.login.activate")
        case .forgotPassword:
            L("auth.login.forgotPassword")
        case .resetPassword:
            L("auth.login.resetPassword")
        }
    }

    private var plainHeaderSubtitle: String? {
        switch step {
        case .enterEmail, .login:
            switch localization.language {
            case .simplifiedChinese:
                "登录后即可使用 Typeflux Cloud 提供的语音识别和模型推理服务"
            case .traditionalChinese:
                "登入後即可使用 Typeflux Cloud 提供的語音辨識和模型推理服務"
            case .japanese:
                "サインインすると、Typeflux Cloud の音声認識とモデル推論サービスを利用できます"
            case .korean:
                "로그인하면 Typeflux Cloud가 제공하는 음성 인식 및 모델 추론 서비스를 사용할 수 있습니다"
            case .english:
                "Sign in to use Typeflux Cloud speech recognition and model inference services."
            }
        case .register, .activate, .forgotPassword, .resetPassword:
            nil
        }
    }

    private var resendActivationButtonTitle: String {
        if resendCooldownRemaining > 0 {
            return L("auth.login.resendActivationCountdown", resendCooldownRemaining)
        }

        return L("auth.login.resendActivation")
    }

    private var brandEyebrowColor: Color {
        colorScheme == .dark ? StudioTheme.accent.opacity(0.92) : StudioTheme.accent.opacity(0.86)
    }

    private var headerSubtitleColor: Color {
        if presentationStyle == .plain, colorScheme == .light {
            return Color.black.opacity(0.58)
        }
        return StudioTheme.textSecondary
    }

    private var helperTextColor: Color {
        colorScheme == .dark ? StudioTheme.textTertiary : Color.black.opacity(0.42)
    }

    private var policyTextColor: Color {
        colorScheme == .dark ? StudioTheme.textSecondary : Color.black.opacity(0.5)
    }

    private var agreementSeparatorText: String {
        switch localization.language {
        case .simplifiedChinese, .traditionalChinese:
            "和"
        case .japanese:
            "と"
        case .korean:
            "및"
        case .english:
            "and"
        }
    }

    private var agreementTermsTitle: String {
        switch localization.language {
        case .simplifiedChinese:
            "《用户协议》"
        case .traditionalChinese:
            "《使用者協議》"
        case .japanese:
            "利用規約"
        case .korean:
            "이용약관"
        case .english:
            "Terms of Service"
        }
    }

    private var agreementPrivacyTitle: String {
        switch localization.language {
        case .simplifiedChinese:
            "《隐私政策》"
        case .traditionalChinese:
            "《隱私政策》"
        case .japanese:
            "プライバシーポリシー"
        case .korean:
            "개인정보 처리방침"
        case .english:
            "Privacy Policy"
        }
    }

    private func checkEmail() {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("auth.error.emailRequired")
            return
        }
        clearMessages()
        isLoading = true

        Task {
            do {
                let response = try await AuthAPIService.enterEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
                isLoading = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = response.exists ? .login : .register
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performLogin() {
        guard !password.isEmpty else {
            errorMessage = L("auth.error.passwordRequired")
            return
        }
        clearMessages()
        isLoading = true

        Task {
            do {
                let response = try await AuthAPIService.login(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                await authState.handleLoginSuccess(
                    token: response.accessToken,
                    expiresAt: response.expiresAt,
                    refreshToken: response.refreshToken
                )
                isLoading = false
                onDismiss()
            } catch let error as AuthError {
                isLoading = false
                if error.authErrorCode == "AUTH_USER_NOT_ACTIVE" {
                    previousStepBeforeActivate = .login
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .activate
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performRegister() {
        if let validationError = validatePasswordInput(password) {
            errorMessage = validationError
            return
        }
        guard password == confirmPassword else {
            errorMessage = L("auth.error.passwordMismatch")
            return
        }
        clearMessages()
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.register(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password,
                    name: name.isEmpty ? nil : name
                )
                isLoading = false
                statusMessage = L("auth.login.activationCodeSent")
                resendCooldownRemaining = 60
                previousStepBeforeActivate = .register
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .activate
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performActivate() {
        guard !activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("auth.error.codeRequired")
            return
        }
        clearMessages()
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.activate(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: activationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let loginResponse = try await AuthAPIService.login(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                await authState.handleLoginSuccess(
                    token: loginResponse.accessToken,
                    expiresAt: loginResponse.expiresAt,
                    refreshToken: loginResponse.refreshToken
                )
                isLoading = false
                onDismiss()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resendActivationCode() {
        guard resendCooldownRemaining == 0 else { return }
        clearMessages()
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.resendActivation(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                isLoading = false
                statusMessage = L("auth.login.activationCodeResent")
                resendCooldownRemaining = 60
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openForgotPassword() {
        clearMessages()
        withAnimation(.easeInOut(duration: 0.2)) {
            step = .forgotPassword
        }
    }

    private func performForgotPassword() {
        clearMessages()
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.forgotPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
                isLoading = false
                statusMessage = L("auth.login.resetCodeSent")
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .resetPassword
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performResetPassword() {
        guard !resetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("auth.error.resetCodeRequired")
            return
        }
        if let validationError = validatePasswordInput(resetPassword) {
            errorMessage = validationError
            return
        }
        guard resetPassword == resetPasswordConfirmation else {
            errorMessage = L("auth.error.passwordMismatch")
            return
        }
        clearMessages()
        isLoading = true

        Task {
            do {
                _ = try await AuthAPIService.resetPassword(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: resetCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    newPassword: resetPassword
                )
                let loginResponse = try await AuthAPIService.login(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: resetPassword
                )
                await authState.handleLoginSuccess(
                    token: loginResponse.accessToken,
                    expiresAt: loginResponse.expiresAt,
                    refreshToken: loginResponse.refreshToken
                )
                isLoading = false
                onDismiss()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func validatePasswordInput(_ candidate: String) -> String? {
        guard !candidate.isEmpty else {
            return L("auth.error.passwordRequired")
        }
        guard candidate.count >= 8 else {
            return L("auth.error.passwordTooShort")
        }
        let hasUppercase = candidate.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasLowercase = candidate.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasDigit = candidate.rangeOfCharacter(from: .decimalDigits) != nil
        guard hasUppercase, hasLowercase, hasDigit else {
            return L("auth.error.passwordTooWeak")
        }

        return nil
    }

    private func clearMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    private func performGoogleLogin() {
        guard !googleClientID.isEmpty else { return }
        if let policyError = LoginGooglePreflight.errorMessage(
            for: step,
            hasAcceptedPolicies: hasAcceptedPolicies
        ) {
            statusMessage = nil
            errorMessage = policyError
            return
        }
        clearMessages()
        isGoogleLoading = true

        Task {
            do {
                let idToken = try await GoogleOAuthService.signIn(
                    clientID: googleClientID,
                    clientSecret: googleClientSecret.isEmpty ? nil : googleClientSecret
                )
                let response = try await AuthAPIService.loginWithGoogle(idToken: idToken)
                await authState.handleLoginSuccess(
                    token: response.accessToken,
                    expiresAt: response.expiresAt,
                    refreshToken: response.refreshToken
                )
                isGoogleLoading = false
                onDismiss()
            } catch {
                isGoogleLoading = false
                // ASWebAuthenticationSession cancellation produces a specific error; suppress it silently.
                let nsError = error as NSError
                if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                   nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performAppleLogin() {
        if !hasAcceptedPolicies, step == .enterEmail {
            statusMessage = nil
            errorMessage = AppLocalization.shared.string("auth.error.policyAgreementRequired")
            return
        }
        clearMessages()
        isAppleLoading = true

        Task {
            do {
                let idToken = try await AppleSignInService.signIn()
                let response = try await AuthAPIService.loginWithApple(idToken: idToken)
                await authState.handleLoginSuccess(
                    token: response.accessToken,
                    expiresAt: response.expiresAt,
                    refreshToken: response.refreshToken
                )
                isAppleLoading = false
                onDismiss()
            } catch {
                isAppleLoading = false
                let nsError = error as NSError
                if nsError.domain == ASAuthorizationError.errorDomain,
                   nsError.code == ASAuthorizationError.canceled.rawValue {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performGitHubLogin() {
        guard !githubClientID.isEmpty else { return }
        if !hasAcceptedPolicies, step == .enterEmail {
            statusMessage = nil
            errorMessage = AppLocalization.shared.string("auth.error.policyAgreementRequired")
            return
        }
        clearMessages()
        isGitHubLoading = true

        Task {
            do {
                let authorization = try await GitHubOAuthService.signIn(clientID: githubClientID)
                let response = try await AuthAPIService.loginWithGitHub(
                    code: authorization.code,
                    codeVerifier: authorization.codeVerifier
                )
                await authState.handleLoginSuccess(
                    token: response.accessToken,
                    expiresAt: response.expiresAt,
                    refreshToken: response.refreshToken
                )
                isGitHubLoading = false
                onDismiss()
            } catch {
                isGitHubLoading = false
                // ASWebAuthenticationSession cancellation produces a specific error; suppress it silently.
                let nsError = error as NSError
                if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                   nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func goBack() {
        clearMessages()
        switch step {
        case .enterEmail:
            break
        case .login, .register:
            password = ""
            confirmPassword = ""
            step = .enterEmail
        case .activate:
            activationCode = ""
            resendCooldownRemaining = 0
            step = previousStepBeforeActivate
        case .forgotPassword:
            step = .login
        case .resetPassword:
            resetCode = ""
            resetPassword = ""
            resetPasswordConfirmation = ""
            step = .forgotPassword
        }
    }
}

private struct LoginTextField: View {
    @Environment(\.colorScheme) private var colorScheme
    let placeholder: String
    @Binding var text: String
    let icon: String
    var isSecure: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 20)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .disabled(isDisabled)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.studioBody(StudioTheme.Typography.body))
                    .disabled(isDisabled)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .fill(fieldBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(fieldBorderColor, lineWidth: StudioTheme.BorderWidth.thin)
        )
        .shadow(color: fieldShadowColor, radius: fieldShadowRadius, x: 0, y: fieldShadowY)
        .opacity(isDisabled ? 0.6 : 1)
    }

    private var fieldBackgroundColor: Color {
        colorScheme == .dark
            ? StudioTheme.surfaceMuted
            : Color.white.opacity(0.92)
    }

    private var fieldBorderColor: Color {
        colorScheme == .dark
            ? StudioTheme.border
            : Color.black.opacity(0.10)
    }

    private var fieldShadowColor: Color {
        colorScheme == .dark ? .clear : Color.black.opacity(0.03)
    }

    private var fieldShadowRadius: CGFloat {
        colorScheme == .dark ? 0 : 10
    }

    private var fieldShadowY: CGFloat {
        colorScheme == .dark ? 0 : 3
    }
}

/// A simple Google-branded "G" mark used on the sign-in button.
private struct GoogleLogoMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Text("G")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
        }
        .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
    }
}

/// A simple GitHub Octocat-inspired mark used on the sign-in button.
private struct GitHubLogoMark: View {
    var body: some View {
        Image(systemName: "cat.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white)
    }
}

/// Apple logo mark used on the Sign in with Apple button.
private struct AppleLogoMark: View {
    var body: some View {
        Image(systemName: "apple.logo")
            .font(.system(size: 15, weight: .medium))
    }
}
