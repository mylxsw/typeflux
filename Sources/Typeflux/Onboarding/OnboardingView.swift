import AppKit
import SwiftUI

private struct OnboardingVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.isEmphasized = false
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

// swiftlint:disable file_length type_body_length
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let appearanceMode: AppearanceMode
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var authState = AuthState.shared
    @State private var googleCloudOAuthAuthorized = GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable()
    @State private var isAuthorizingGoogleCloudOAuth = false
    @Environment(\.colorScheme) private var colorScheme

    private let languageColumns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                windowBackdrop

                onboardingCanvas(in: proxy.size)
                    .padding(.horizontal, 20)
                    .padding(.top, 52)
                    .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
        .alert(
            L("onboarding.permissions.incompleteAlert.title"),
            isPresented: $viewModel.showIncompletePermissionsAlert,
        ) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("onboarding.permissions.incompleteAlert.message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if viewModel.currentStep == .permissions {
                viewModel.refreshPermissions()
            }
            if viewModel.currentStep == .shortcuts {
                viewModel.refreshGlobeKeyState()
            }
        }
    }

    private var windowBackdrop: some View {
        ZStack {
            StudioTheme.windowBackground
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    isDarkMode
                        ? Color(red: 0.085, green: 0.085, blue: 0.095)
                        : Color(red: 0.985, green: 0.982, blue: 0.976),
                    isDarkMode
                        ? Color(red: 0.06, green: 0.06, blue: 0.07)
                        : Color(red: 0.94, green: 0.95, blue: 0.965),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    StudioTheme.accent.opacity(isDarkMode ? 0.16 : 0.10),
                    Color.clear,
                ],
                center: .topTrailing,
                startRadius: 24,
                endRadius: 460,
            )
            .ignoresSafeArea()
        }
    }

    private func onboardingCanvas(in size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            canvasAmbientGlow
            VStack(spacing: 0) {
                canvasTopBar

                ScrollView(showsIndicators: false) {
                    stepContent(in: size)
                        .padding(.horizontal, horizontalPadding(for: size.width))
                        .padding(.top, 18)
                        .padding(.bottom, 110)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            footerBar
                .frame(maxWidth: min(canvasWidth(for: viewModel.currentStep), size.width - 44))
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canvasAmbientGlow: some View {
        Color.clear
    }

    private var canvasTopBar: some View {
        Color.clear.frame(height: 0)
    }

    private var stepCounterText: String {
        guard let currentIndex = viewModel.visibleSteps.firstIndex(of: viewModel.currentStep) else {
            return "01 / 01"
        }
        return String(format: "%02d / %02d", currentIndex + 1, viewModel.visibleSteps.count)
    }

    private func stepEyebrow(for step: OnboardingViewModel.Step) -> String {
        switch step {
        case .language:
            "Language"
        case .account:
            "Typeflux Cloud"
        case .stt:
            "Voice Recognition"
        case .llm:
            "AI Configuration"
        case .permissions:
            "Permissions"
        case .shortcuts:
            "Keyboard Shortcuts"
        }
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        width > 980 ? 58 : 34
    }

    private func canvasWidth(for step: OnboardingViewModel.Step) -> CGFloat {
        switch step {
        case .language, .shortcuts:
            1030
        case .account:
            860
        case .permissions:
            940
        case .stt, .llm:
            1040
        }
    }

    @ViewBuilder
    private func stepContent(in size: CGSize) -> some View {
        switch viewModel.currentStep {
        case .language:
            languageStep(contentHeight: availableContentHeight(in: size))
        case .account:
            accountStep(contentHeight: availableContentHeight(in: size))
        case .stt:
            sttStep
        case .llm:
            llmStep
        case .permissions:
            permissionsStep(contentHeight: availableContentHeight(in: size))
        case .shortcuts:
            shortcutsStep
        }
    }

    private func availableContentHeight(in size: CGSize) -> CGFloat {
        max(420, size.height - 220)
    }

    private func languageStep(contentHeight: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 22) {
                editorialStepHeader(
                    title: L("onboarding.language.title"),
                    subtitle: L("onboarding.language.subtitle"),
                    alignCenter: false,
                )

                LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 18) {
                    ForEach(AppLanguage.allCases) { language in
                        languageCard(language)
                            .gridCellColumns(language == .korean ? 2 : 1)
                    }
                }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(minHeight: contentHeight)
    }

    private func accountStep(contentHeight: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .center, spacing: 28) {
                if authState.isLoggedIn {
                    editorialStepHeader(
                        eyebrow: stepEyebrow(for: .account),
                        title: L("onboarding.account.title"),
                        subtitle: L("onboarding.account.subtitle"),
                        alignCenter: true,
                        showStepCounter: false,
                    )
                }

                VStack(spacing: 18) {
                    if authState.isLoggedIn {
                        signedInAccountCard
                    } else {
                        LoginView(presentationStyle: .plain) {
                            viewModel.useCloudAccountModelsAndContinue()
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 660, alignment: .center)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(minHeight: contentHeight)
    }

    private var signedInAccountCard: some View {
        onboardingConfigCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(StudioTheme.accent)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(authState.userProfile?.resolvedDisplayName ?? L("provider.llm.typefluxCloud"))
                            .font(.studioDisplay(18, weight: .bold))
                            .foregroundStyle(onboardingPrimaryText)
                        Text(authState.userProfile?.email ?? L("onboarding.account.subtitle"))
                            .font(.studioBody(12))
                            .foregroundStyle(onboardingSecondaryText)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.accent)
                    Text(L("onboarding.account.cloudReady"))
                        .font(.studioBody(12))
                        .foregroundStyle(onboardingSecondaryText)
                }
            }
        }
    }

    private func languageCard(_ language: AppLanguage) -> some View {
        let isSelected = viewModel.appLanguage == language

        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                viewModel.setLanguage(language)
            }
        } label: {
            HStack(spacing: 14) {
                Text(language.displayName)
                    .font(.studioDisplay(15, weight: .bold))
                    .foregroundStyle(onboardingPrimaryText)

                Spacer()

                languageSelectionIndicator(isSelected: isSelected)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(languageCardFill(isSelected: isSelected))
            .overlay(languageCardStroke(isSelected: isSelected))
            .shadow(color: isSelected ? StudioTheme.accent.opacity(0.16) : .clear, radius: 20, x: 0, y: 10)
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func languageSelectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? StudioTheme.accent.opacity(0.32) : onboardingSelectionRing, lineWidth: 1)
                .frame(width: 28, height: 28)

            if isSelected {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.66, green: 0.78, blue: 1.0), StudioTheme.accent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing,
                        ),
                    )
                    .frame(width: 28, height: 28)
                    .shadow(color: StudioTheme.accent.opacity(0.45), radius: 16, x: 0, y: 6)

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(onboardingSelectionCheckmark)
            }
        }
    }

    private var sttStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            editorialStepHeader(
                eyebrow: "Step 03",
                title: L("onboarding.models.stt.title"),
                subtitle: L("onboarding.sttProvider.subtitle"),
                alignCenter: false,
            )

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    ForEach(
                        STTProvider.onboardingDisplayOrder.filter { provider in
                            provider != .freeModel || !FreeSTTModelRegistry.suggestedModelNames.isEmpty
                        },
                        id: \.self
                    ) { provider in
                        modelProviderCard(
                            providerID: sttProviderToID(provider),
                            title: provider.displayName,
                            description: sttProviderDescription(provider),
                            badge: sttProviderBadge(provider),
                            isSelected: viewModel.sttProvider == provider,
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.selectSTTProvider(provider)
                            }
                        }
                    }
                }
                .frame(width: OnboardingProviderStyle.listColumnWidth)

                sttConfigPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func progressBadge(progress: Double, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(onboardingProgressTrack)
                    .frame(width: 140, height: 4)
                Capsule(style: .continuous)
                    .fill(StudioTheme.accent)
                    .frame(width: 140 * progress, height: 4)
            }

            Text(label)
                .font(.studioBody(10, weight: .semibold))
                .foregroundStyle(onboardingTertiaryText)
        }
    }

    @ViewBuilder
    private func sttInlineConfig(for provider: STTProvider) -> some View {
        switch provider {
        case .freeModel:
            freeSTTConfigFields
        case .whisperAPI:
            whisperConfigFields
        case .localModel:
            localSTTConfigFields
        case .multimodalLLM:
            multimodalLLMConfigFields
        case .aliCloud:
            aliCloudConfigFields
        case .doubaoRealtime:
            doubaoConfigFields
        case .googleCloud:
            googleCloudConfigFields
        case .groq:
            groqSTTConfigFields
        case .appleSpeech, .typefluxOfficial:
            EmptyView()
        }
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            editorialStepHeader(
                eyebrow: "Configuration",
                title: L("onboarding.models.llm.title"),
                subtitle: L("onboarding.llmProvider.subtitle"),
                alignCenter: false,
            )

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    if !FreeLLMModelRegistry.suggestedModelNames.isEmpty {
                        ForEach(
                            LLMRemoteProvider.settingsDisplayOrder
                                .filter { $0 == .freeModel }
                                .prefix(1),
                            id: \.self,
                        ) { provider in
                            let isSelected = viewModel.llmProvider == .openAICompatible
                                && viewModel.llmRemoteProvider == provider
                            modelProviderCard(
                                providerID: provider.studioProviderID,
                                title: provider.displayName,
                                description: L("settings.models.card.\(provider.rawValue).summary"),
                                badge: L("settings.models.badge.free"),
                                isSelected: isSelected,
                            ) {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    viewModel.selectLLMRemoteProvider(provider)
                                }
                            }
                        }
                    }

                    ForEach(
                        LLMRemoteProvider.onboardingDisplayOrder.filter { $0 != .custom },
                        id: \.self
                    ) { provider in
                        let isSelected = viewModel.llmProvider == .openAICompatible
                            && viewModel.llmRemoteProvider == provider
                        modelProviderCard(
                            providerID: provider.studioProviderID,
                            title: provider.displayName,
                            description: L("settings.models.card.\(provider.rawValue).summary"),
                            badge: provider.apiStyle == .openAICompatible
                                ? L("settings.models.badge.api")
                                : L("settings.models.badge.native"),
                            isSelected: isSelected,
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.selectLLMRemoteProvider(provider)
                            }
                        }
                    }

                    modelProviderCard(
                        providerID: .ollama,
                        title: L("provider.llm.ollama"),
                        description: L("settings.models.card.ollama.summary"),
                        badge: L("settings.models.badge.local"),
                        isSelected: viewModel.llmProvider == .ollama,
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.selectOllama()
                        }
                    }

                    ForEach(
                        LLMRemoteProvider.onboardingDisplayOrder.filter { $0 == .custom },
                        id: \.self
                    ) { provider in
                        let isSelected = viewModel.llmProvider == .openAICompatible
                            && viewModel.llmRemoteProvider == provider
                        modelProviderCard(
                            providerID: provider.studioProviderID,
                            title: provider.displayName,
                            description: L("settings.models.card.\(provider.rawValue).summary"),
                            badge: L("settings.models.badge.api"),
                            isSelected: isSelected,
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.selectLLMRemoteProvider(provider)
                            }
                        }
                    }
                }
                .frame(width: OnboardingProviderStyle.listColumnWidth)

                llmConfigPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var whisperConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioSuggestedTextInputCard(
                    label: L("settings.models.whisper.endpoint"),
                    placeholder: OpenAIAudioModelCatalog.whisperEndpoints[0],
                    text: $viewModel.whisperBaseURL,
                    suggestions: OpenAIAudioModelCatalog.whisperEndpoints,
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.whisperAPIKey,
                    secure: true,
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.defaultWhisperModel(
                        forEndpoint: viewModel.whisperBaseURL,
                    ),
                    text: $viewModel.whisperModel,
                    suggestions: OpenAIAudioModelCatalog.suggestedWhisperModels(
                        forEndpoint: viewModel.whisperBaseURL,
                    ),
                )
            }
        }
    }

    private var freeSTTConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                if FreeSTTModelRegistry.suggestedModelNames.isEmpty {
                    Text(L("settings.models.freeSTT.noSources"))
                        .font(.studioBody(12))
                        .foregroundStyle(onboardingSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    StudioMenuPicker(
                        options: FreeSTTModelRegistry.suggestedModelNames.map { ($0, $0) },
                        selection: $viewModel.freeSTTModel,
                        width: 320,
                    )
                }

                Text(L("settings.models.freeSTT.hint"))
                    .font(.studioBody(12))
                    .foregroundStyle(onboardingSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var localSTTConfigFields: some View {
        VStack(spacing: 10) {
            ForEach(LocalSTTModel.displayOrder, id: \.self) { model in
                let isSelected = viewModel.localSTTModel == model

                Button {
                    viewModel.localSTTModel = model
                } label: {
                    HStack(spacing: 14) {
                        languageSelectionIndicator(isSelected: isSelected)
                            .scaleEffect(0.78)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.studioBody(14, weight: .semibold))
                                    .foregroundStyle(onboardingPrimaryText)

                                if let recommendationBadgeTitle = model.recommendationBadgeTitle {
                                    onboardingRecommendationPill(recommendationBadgeTitle)
                                }
                            }

                            Text(model.specs.summary)
                                .font(.studioBody(12))
                                .foregroundStyle(onboardingSecondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(model.specs.sizeValue)
                            .font(.studioBody(11, weight: .semibold))
                            .foregroundStyle(isSelected ? StudioTheme.accent.opacity(0.92) : onboardingTertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? onboardingSelectedBadgeFill : onboardingBadgeFill),
                            )
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(languageCardFill(isSelected: isSelected))
                    .overlay(languageCardStroke(isSelected: isSelected))
                }
                .buttonStyle(StudioInteractiveButtonStyle())
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(onboardingTertiaryText)
                Text(L("onboarding.models.stt.local.hint"))
                    .font(.studioBody(12))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    private func onboardingRecommendationPill(_ text: String) -> some View {
        Text(text)
            .font(.studioBody(10, weight: .bold))
            .foregroundStyle(Color.green.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.green.opacity(0.16)),
            )
    }

    private var multimodalLLMConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioSuggestedTextInputCard(
                    label: L("settings.models.remote.baseURL"),
                    placeholder: OpenAIAudioModelCatalog.multimodalEndpoints[0],
                    text: $viewModel.multimodalLLMBaseURL,
                    suggestions: OpenAIAudioModelCatalog.multimodalEndpoints,
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.multimodalLLMAPIKey,
                    secure: true,
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.multimodalModels[0],
                    text: $viewModel.multimodalLLMModel,
                    suggestions: OpenAIAudioModelCatalog.multimodalModels,
                )
            }
        }
    }

    private var aliCloudConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.aliCloudAPIKey,
                    secure: true,
                )
            }
        }
    }

    private var doubaoConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("settings.models.doubao.appID"),
                    placeholder: "",
                    text: $viewModel.doubaoAppID,
                )
                StudioTextInputCard(
                    label: L("settings.models.doubao.accessToken"),
                    placeholder: "",
                    text: $viewModel.doubaoAccessToken,
                    secure: true,
                )
            }
        }
    }

    private var googleCloudConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("settings.models.googleCloud.projectID"),
                    placeholder: "my-gcp-project",
                    text: $viewModel.googleCloudProjectID,
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: GoogleCloudSpeechDefaults.model,
                    text: $viewModel.googleCloudModel,
                    suggestions: GoogleCloudSpeechDefaults.suggestedModels,
                )
                HStack(spacing: 12) {
                    StudioButton(
                        title: googleCloudOAuthAuthorized
                            ? L("settings.models.googleCloud.oauth.reauthorize")
                            : L("settings.models.googleCloud.oauth.authorize"),
                        systemImage: "person.crop.circle.badge.checkmark",
                        variant: .secondary,
                        isDisabled: AppServerConfiguration.googleCloudOAuthClientID.isEmpty || isAuthorizingGoogleCloudOAuth,
                        isLoading: isAuthorizingGoogleCloudOAuth,
                    ) {
                        authorizeGoogleCloudFromOnboarding()
                    }

                    if googleCloudOAuthAuthorized {
                        StudioButton(
                            title: L("settings.models.googleCloud.oauth.disconnect"),
                            systemImage: "xmark.circle",
                            variant: .ghost,
                        ) {
                            GoogleCloudSpeechOAuthTokenStore.clear()
                            googleCloudOAuthAuthorized = false
                            viewModel.googleCloudAPIKey = ""
                        }
                    }

                    Spacer()
                }
            }
        }
    }

    private func authorizeGoogleCloudFromOnboarding() {
        guard !isAuthorizingGoogleCloudOAuth else { return }

        isAuthorizingGoogleCloudOAuth = true
        viewModel.sttConnectionTestState = .idle

        Task { @MainActor in
            defer {
                isAuthorizingGoogleCloudOAuth = false
            }

            do {
                let token = try await GoogleOAuthService.authorizeGoogleCloud(
                    clientID: AppServerConfiguration.googleCloudOAuthClientID,
                    clientSecret: AppServerConfiguration.googleCloudOAuthClientSecret.isEmpty
                        ? nil : AppServerConfiguration.googleCloudOAuthClientSecret,
                )
                GoogleCloudSpeechOAuthTokenStore.save(token)
                viewModel.googleCloudAPIKey = ""
                googleCloudOAuthAuthorized = true
            } catch {
                viewModel.sttConnectionTestState = .failure(message: error.localizedDescription)
            }
        }
    }

    private var groqSTTConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "gsk_...",
                    text: $viewModel.groqSTTAPIKey,
                    secure: true,
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.groqWhisperModels[0],
                    text: $viewModel.groqSTTModel,
                    suggestions: OpenAIAudioModelCatalog.groqWhisperModels,
                )
            }
        }
    }

    private var llmRemoteConfigFields: some View {
        let provider = viewModel.llmRemoteProvider
        let endpointSuggestions = ([viewModel.llmBaseURL, provider.defaultBaseURL]
            + provider.endpointPresets.map(\.url))
            .filter { !$0.isEmpty }
        let modelSuggestions = ([viewModel.llmModel] + provider.suggestedModels)
            .filter { !$0.isEmpty }

        return Group {
            if provider == .typefluxCloud {
                EmptyView()
            } else {
                onboardingConfigCard {
                    VStack(spacing: 12) {
                        if provider == .freeModel {
                            if FreeLLMModelRegistry.suggestedModelNames.isEmpty {
                                Text(L("settings.models.freeModel.noSources"))
                                    .font(.studioBody(12))
                                    .foregroundStyle(Color.white.opacity(0.48))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                StudioMenuPicker(
                                    options: FreeLLMModelRegistry.suggestedModelNames.map { ($0, $0) },
                                    selection: $viewModel.llmModel,
                                    width: 320,
                                )
                            }
                            Text(L("settings.models.freeModel.hint"))
                                .font(.studioBody(12))
                                .foregroundStyle(Color.white.opacity(0.48))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            StudioTextInputCard(
                                label: L("common.apiKey"),
                                placeholder: provider == .gemini ? "AIza..." : "sk-...",
                                text: $viewModel.llmAPIKey,
                                secure: true,
                            )
                            StudioSuggestedTextInputCard(
                                label: L("settings.models.remote.baseURL"),
                                placeholder: provider.defaultBaseURL.isEmpty
                                    ? "https://api.openai.com/v1" : provider.defaultBaseURL,
                                text: $viewModel.llmBaseURL,
                                suggestions: endpointSuggestions,
                            )
                            StudioSuggestedTextInputCard(
                                label: L("common.model"),
                                placeholder: provider.defaultModel,
                                text: $viewModel.llmModel,
                                suggestions: modelSuggestions,
                            )
                        }
                    }
                }
            }
        }
    }

    private var ollamaConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioSuggestedTextInputCard(
                    label: L("settings.models.ollama.baseURL"),
                    placeholder: "http://127.0.0.1:11434",
                    text: $viewModel.ollamaBaseURL,
                    suggestions: [viewModel.ollamaBaseURL, "http://127.0.0.1:11434", "http://localhost:11434"]
                        .filter { !$0.isEmpty },
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: "qwen2.5:7b",
                    text: $viewModel.ollamaModel,
                    suggestions: [viewModel.ollamaModel, "qwen2.5:7b", "llama3.2:3b", "gemma3:4b"]
                        .filter { !$0.isEmpty },
                )
            }
        }
    }

    private func onboardingConfigCard(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(16)
            .background(onboardingCardFill)
            .overlay(onboardingCardStroke)
    }

    private var sttConfigPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.studioBody(10, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(onboardingTertiaryText)

            Text(viewModel.sttProvider.displayName)
                .font(.studioDisplay(18, weight: .bold))
                .foregroundStyle(onboardingPrimaryText)

            Text(sttProviderDescription(viewModel.sttProvider))
                .font(.studioBody(12))
                .foregroundStyle(onboardingSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if sttProviderNeedsConfiguration(viewModel.sttProvider) {
                    sttInlineConfig(for: viewModel.sttProvider)
                } else {
                    onboardingConfigCard {
                        Text("This provider is ready to use with the current defaults.")
                            .font(.studioBody(12))
                            .foregroundStyle(onboardingSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if sttProviderSupportsTest(viewModel.sttProvider) {
                HStack(spacing: 12) {
                    if let url = sttProviderAPIKeyURL(viewModel.sttProvider) {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Image(systemName: "key")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L("onboarding.models.getAPIKey"))
                                    .font(.studioBody(12, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(StudioTheme.accent)
                        }
                    }

                    Spacer()

                    StudioButton(
                        title: viewModel.sttConnectionTestState == .testing
                            ? L("settings.models.testingConnection") : L("settings.models.testConnection"),
                        systemImage: viewModel.sttConnectionTestState == .testing ? nil : "network",
                        variant: .secondary,
                        isDisabled: viewModel.sttConnectionTestState == .testing,
                        isLoading: viewModel.sttConnectionTestState == .testing,
                    ) {
                        viewModel.testSTTConnection()
                    }
                }
                .frame(maxWidth: .infinity)

                connectionTestResultView(viewModel.sttConnectionTestState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var llmConfigPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.studioBody(10, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(onboardingTertiaryText)

            Text(viewModel.llmProvider == .ollama ? L("provider.llm.ollama") : viewModel.llmRemoteProvider.displayName)
                .font(.studioDisplay(18, weight: .bold))
                .foregroundStyle(onboardingPrimaryText)

            Text(viewModel.llmProvider == .ollama
                ? L("settings.models.card.ollama.summary")
                : L("settings.models.card.\(viewModel.llmRemoteProvider.rawValue).summary"))
                .font(.studioBody(12))
                .foregroundStyle(onboardingSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if viewModel.llmProvider == .ollama {
                    ollamaConfigFields
                } else {
                    llmRemoteConfigFields
                }
            }

            if llmProviderSupportsTest {
                HStack(spacing: 12) {
                    if let url = llmProviderAPIKeyURL(viewModel.llmRemoteProvider),
                       viewModel.llmProvider != .ollama
                    {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Image(systemName: "key")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L("onboarding.models.getAPIKey"))
                                    .font(.studioBody(12, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(StudioTheme.accent)
                        }
                    }

                    Spacer()

                    StudioButton(
                        title: viewModel.llmConnectionTestState == .testing
                            ? L("settings.models.testingConnection") : L("settings.models.testConnection"),
                        systemImage: viewModel.llmConnectionTestState == .testing ? nil : "network",
                        variant: .secondary,
                        isDisabled: viewModel.llmConnectionTestState == .testing,
                        isLoading: viewModel.llmConnectionTestState == .testing,
                    ) {
                        viewModel.testLLMConnection()
                    }
                }
                .frame(maxWidth: .infinity)

                connectionTestResultView(viewModel.llmConnectionTestState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sttProviderNeedsConfiguration(_ provider: STTProvider) -> Bool {
        switch provider {
        case .appleSpeech:
            false
        default:
            true
        }
    }

    private func sttProviderSupportsTest(_ provider: STTProvider) -> Bool {
        switch provider {
        case .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groq, .freeModel:
            true
        case .localModel, .appleSpeech, .typefluxOfficial:
            false
        }
    }

    private func sttProviderAPIKeyURL(_ provider: STTProvider) -> URL? {
        switch provider {
        case .whisperAPI:
            URL(string: "https://platform.openai.com/api-keys")
        case .groq:
            URL(string: "https://console.groq.com/keys")
        case .aliCloud:
            URL(string: "https://bailian.console.aliyun.com/")
        case .doubaoRealtime:
            URL(string: "https://console.volcengine.com/speech/service/asr")
        case .multimodalLLM:
            URL(string: "https://platform.openai.com/api-keys")
        case .googleCloud, .freeModel, .localModel, .appleSpeech, .typefluxOfficial:
            nil
        }
    }

    private func llmProviderAPIKeyURL(_ provider: LLMRemoteProvider) -> URL? {
        switch provider {
        case .openAI:
            URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:
            URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:
            URL(string: "https://aistudio.google.com/apikey")
        case .deepSeek:
            URL(string: "https://platform.deepseek.com/api_keys")
        case .groq:
            URL(string: "https://console.groq.com/keys")
        case .openRouter:
            URL(string: "https://openrouter.ai/settings/keys")
        case .kimi:
            URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .qwen:
            URL(string: "https://dashscope.console.aliyun.com/apiKey")
        case .zhipu:
            URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikey")
        case .minimax:
            URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        case .grok:
            URL(string: "https://console.x.ai/")
        case .xiaomi:
            URL(string: "https://ai.xiaomi.com/")
        case .freeModel, .custom:
            nil
        case .typefluxCloud:
            nil
        }
    }

    private var llmProviderSupportsTest: Bool {
        if viewModel.llmProvider == .ollama {
            return true
        }

        return switch viewModel.llmRemoteProvider {
        case .freeModel, .typefluxCloud:
            false
        default:
            true
        }
    }

    @ViewBuilder
    private func connectionTestResultView(_ state: OnboardingViewModel.ConnectionTestState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            EmptyView()
        case let .success(totalMs, preview):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StudioTheme.success)
                        .font(.system(size: 13))
                    Text(L("settings.models.connectionSuccess", totalMs, totalMs))
                        .font(.studioBody(12, weight: .semibold))
                        .foregroundStyle(StudioTheme.success)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.studioBody(11))
                        .foregroundStyle(onboardingSecondaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(onboardingMutedSurface),
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(onboardingSubtleBorder, lineWidth: 1),
                        )
                }
            }
        case let .failure(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(StudioTheme.danger)
                    .font(.system(size: 13))
                Text(message)
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sttProviderToID(_ provider: STTProvider) -> StudioModelProviderID {
        switch provider {
        case .freeModel: .freeSTT
        case .whisperAPI: .whisperAPI
        case .localModel: .localSTT
        case .multimodalLLM: .multimodalLLM
        case .aliCloud: .aliCloud
        case .doubaoRealtime: .doubaoRealtime
        case .googleCloud: .googleCloud
        case .groq: .groqSTT
        case .appleSpeech: .appleSpeech
        case .typefluxOfficial: .typefluxOfficial
        }
    }

    private func loadProviderLogo(for providerID: StudioModelProviderID) -> NSImage? {
        guard let name = providerLogoResourceName(for: providerID) else { return nil }
        let url = Bundle.appResources.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Resources/Providers",
        )
            ?? Bundle.appResources.url(forResource: name, withExtension: "png", subdirectory: "Providers")
            ?? Bundle.appResources.url(forResource: name, withExtension: "png")
            ?? Bundle.appResources.url(forResource: name, withExtension: "svg", subdirectory: "Resources")
            ?? Bundle.appResources.url(forResource: name, withExtension: "svg")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private func providerLogoResourceName(for providerID: StudioModelProviderID) -> String? {
        switch providerID {
        case .freeSTT: nil
        case .whisperAPI, .multimodalLLM: "openai"
        case .ollama: "ollama"
        case .freeModel: nil
        case .openRouter: "openrouter"
        case .openAI: "openai"
        case .anthropic: "claude-color"
        case .gemini: "gemini-color"
        case .deepSeek: "deepseek-color"
        case .kimi: "moonshot"
        case .qwen: "qwen-color"
        case .zhipu: "zhipu-color"
        case .minimax: "minimax-color"
        case .grok: "xai"
        case .groq: "groq"
        case .groqSTT: "groq"
        case .googleCloud: "google"
        case .xiaomi: "xiaomimimo"
        case .aliCloud: "bailian-color"
        case .doubaoRealtime: "doubao-color"
        default: nil
        }
    }

    private func providerSymbol(for providerID: StudioModelProviderID) -> String {
        switch providerID {
        case .appleSpeech: "waveform"
        case .localSTT: "laptopcomputer.and.arrow.down"
        case .freeSTT: "giftcard"
        case .whisperAPI: "dot.radiowaves.left.and.right"
        case .ollama: "cpu"
        case .freeModel: "giftcard"
        case .customLLM: "slider.horizontal.3"
        case .openRouter: "arrow.triangle.branch"
        case .openAI: "circle.hexagongrid"
        case .anthropic: "sun.max"
        case .gemini: "diamond"
        case .deepSeek: "bird"
        case .kimi: "moon.stars"
        case .qwen: "cloud"
        case .zhipu: "dot.scope"
        case .minimax: "sparkles"
        case .grok: "x.circle"
        case .groq: "bolt.fill"
        case .groqSTT: "bolt.fill"
        case .googleCloud: "cloud"
        case .xiaomi: "circle.grid.cross"
        case .multimodalLLM: "brain.filled.head.profile"
        case .aliCloud: "antenna.radiowaves.left.and.right"
        case .doubaoRealtime: "bolt.horizontal.circle"
        case .typefluxOfficial: "infinity"
        case .typefluxCloud: "infinity"
        }
    }

    private func sttProviderBadge(_ provider: STTProvider) -> String {
        switch provider {
        case .localModel: L("settings.models.badge.local")
        case .freeModel: L("settings.models.badge.free")
        default: L("settings.models.badge.api")
        }
    }

    private func sttProviderDescription(_ provider: STTProvider) -> String {
        switch provider {
        case .freeModel: L("settings.models.card.freeSTT.summary")
        case .whisperAPI: L("settings.models.card.whisper.summary")
        case .localModel: L("settings.models.card.localSTT.summary")
        case .multimodalLLM: L("settings.models.card.multimodal.summary")
        case .aliCloud: L("settings.models.card.aliCloud.summary")
        case .doubaoRealtime: L("settings.models.card.doubao.summary")
        case .googleCloud: L("settings.models.card.googleCloud.summary")
        case .groq: L("settings.models.card.groq.summary")
        case .appleSpeech: ""
        case .typefluxOfficial: L("settings.models.card.typefluxOfficial.summary")
        }
    }

    private func modelProviderCard(
        providerID: StudioModelProviderID,
        title: String,
        description: String,
        badge: String,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                providerIconBadge(for: providerID, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.studioBody(14, weight: .semibold))
                        .foregroundStyle(onboardingPrimaryText)
                    Text(description)
                        .font(.studioBody(11))
                        .foregroundStyle(onboardingSecondaryText)
                        .lineLimit(2)
                }

                Spacer()

                Text(badge)
                    .font(.studioBody(9, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(isSelected ? StudioTheme.accent.opacity(0.95) : onboardingTertiaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? onboardingSelectedBadgeFill : onboardingBadgeFill),
                    )

                languageSelectionIndicator(isSelected: isSelected)
                    .scaleEffect(0.82)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(languageCardFill(isSelected: isSelected))
            .overlay(languageCardStroke(isSelected: isSelected))
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func providerIconBadge(for providerID: StudioModelProviderID, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(providerIconBadgeBackground(for: providerID, isSelected: isSelected))
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(providerIconBadgeBorder(for: providerID, isSelected: isSelected), lineWidth: 1),
            )
            .overlay(
                Group {
                    if providerID.usesTypefluxBranding {
                        TypefluxLogoBadge(
                            size: 30,
                            symbolSize: 15,
                            backgroundShape: .circle,
                            showsBorder: true,
                        )
                    } else if let image = loadProviderLogo(for: providerID) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(providerID.usesExpandedLogo ? 1 : 6)
                    } else {
                        Image(systemName: providerSymbol(for: providerID))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? StudioTheme.accent : onboardingSecondaryText)
                    }
                },
            )
    }

    private func providerIconBadgeBackground(for providerID: StudioModelProviderID, isSelected: Bool) -> LinearGradient {
        switch OnboardingProviderStyle.iconPlateStyle(for: providerID) {
        case .light:
            let top = isSelected
                ? Color(red: 0.96, green: 0.98, blue: 1.0).opacity(0.96)
                : Color.white.opacity(0.92)
            let bottom = isSelected
                ? Color(red: 0.82, green: 0.89, blue: 1.0).opacity(0.88)
                : Color(red: 0.84, green: 0.87, blue: 0.93).opacity(0.84)
            return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .neutral:
            let top = isDarkMode
                ? Color.white.opacity(isSelected ? 0.1 : 0.07)
                : StudioTheme.surface.opacity(isSelected ? 0.96 : 0.92)
            let bottom = isDarkMode
                ? Color(red: 0.12, green: 0.13, blue: 0.17).opacity(isSelected ? 0.72 : 0.82)
                : StudioTheme.surfaceMuted.opacity(isSelected ? 0.98 : 0.94)
            return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func providerIconBadgeBorder(for providerID: StudioModelProviderID, isSelected: Bool) -> Color {
        switch OnboardingProviderStyle.iconPlateStyle(for: providerID) {
        case .light:
            isDarkMode ? Color.white.opacity(isSelected ? 0.28 : 0.18) : StudioTheme.border.opacity(isSelected ? 0.9 : 0.72)
        case .neutral:
            isDarkMode ? Color.white.opacity(isSelected ? 0.12 : 0.08) : StudioTheme.border.opacity(isSelected ? 0.85 : 0.72)
        }
    }

    private func permissionsStep(contentHeight: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                editorialStepHeader(
                    title: L("onboarding.permissions.title"),
                    subtitle: L("onboarding.permissions.subtitle"),
                    alignCenter: false,
                )

                VStack(spacing: 10) {
                    ForEach(PrivacyGuard.PermissionID.allCases) { permissionID in
                        if let snapshot = viewModel.permissions.first(where: { $0.id == permissionID }) {
                            permissionCard(snapshot)
                        }
                    }
                }

                permissionInstruction
                    .padding(.top, 8)
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(minHeight: contentHeight)
    }

    private func permissionCard(_ snapshot: PrivacyGuard.PermissionSnapshot) -> some View {
        let isGranted = snapshot.isGranted
        let isRequesting = viewModel.requestingPermissions.contains(snapshot.id)

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isGranted ? onboardingSelectedBadgeFill : onboardingMutedSurface)
                    .frame(width: 38, height: 38)
                Image(systemName: permissionIcon(snapshot.id))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isGranted ? StudioTheme.success : StudioTheme.accent.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.studioBody(13, weight: .semibold))
                    .foregroundStyle(onboardingPrimaryText)
                Text(snapshot.detail)
                    .font(.studioBody(11))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isGranted {
                Text(snapshot.badgeText)
                    .font(.studioBody(10, weight: .semibold))
                    .foregroundStyle(StudioTheme.success.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(StudioTheme.success.opacity(0.12)),
                    )
            } else {
                StudioButton(
                    title: snapshot.actionTitle,
                    systemImage: "lock.open.display",
                    variant: .primary,
                    isDisabled: isRequesting,
                    isLoading: isRequesting,
                ) {
                    viewModel.requestPermission(snapshot.id)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private var permissionInstruction: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StudioTheme.accent.opacity(isDarkMode ? 0.16 : 0.10)),
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(L("onboarding.permissions.instruction.title"))
                    .font(.studioBody(13, weight: .semibold))
                    .foregroundStyle(onboardingPrimaryText)
                Text(L("onboarding.permissions.instruction.subtitle"))
                    .font(.studioBody(12))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(onboardingMutedSurface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(onboardingSubtleBorder, lineWidth: 1),
        )
    }

    private func permissionIcon(_ id: PrivacyGuard.PermissionID) -> String {
        switch id {
        case .microphone: "mic.fill"
        case .speechRecognition: "waveform"
        case .accessibility: "figure.stand"
        }
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: shortcutsSectionSpacing) {
            editorialStepHeader(
                title: L("onboarding.shortcuts.title"),
                subtitle: L("onboarding.shortcuts.subtitle"),
                alignCenter: false,
            )

            VStack(spacing: shortcutsSectionSpacing) {
                HStack(alignment: .top, spacing: shortcutsSectionSpacing) {
                    shortcutCard(
                        title: L("settings.shortcuts.activation.title"),
                        subtitle: L("onboarding.shortcuts.activation.hint"),
                        binding: HotkeyBinding.defaultActivation,
                        expanded: true,
                    )

                    shortcutCard(
                        title: L("settings.shortcuts.ask.title"),
                        subtitle: L("onboarding.shortcuts.ask.hint"),
                        binding: HotkeyBinding.defaultAsk,
                        expanded: true,
                    )
                }

                shortcutWideCard(
                    title: L("settings.shortcuts.persona.title"),
                    subtitle: L("onboarding.shortcuts.persona.hint"),
                    binding: HotkeyBinding.defaultPersona,
                )
            }

            globeKeyNotice
        }
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func shortcutCard(
        title: String,
        subtitle: String,
        binding: HotkeyBinding,
        expanded: Bool,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.studioDisplay(16, weight: .bold))
                    .foregroundStyle(onboardingPrimaryText)
                    .lineLimit(1)

                Spacer()

                hotkeySequence(binding)
                    .fixedSize()
            }

            Text(subtitle)
                .font(.studioBody(12))
                .foregroundStyle(onboardingSecondaryText)
                .lineLimit(expanded ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: expanded ? .infinity : nil, minHeight: 96, alignment: .topLeading)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private func shortcutWideCard(
        title: String,
        subtitle: String,
        binding: HotkeyBinding,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.studioDisplay(16, weight: .bold))
                    .foregroundStyle(onboardingPrimaryText)
                    .lineLimit(1)

                Spacer()

                hotkeySequence(binding)
                    .fixedSize()
            }

            Text(subtitle)
                .font(.studioBody(12))
                .foregroundStyle(onboardingSecondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private var globeKeyNotice: some View {
        let isReady = viewModel.isGlobeKeyReady
        let accent: Color = isReady ? StudioTheme.success : StudioTheme.warning
        let iconName = isReady ? "checkmark.seal.fill" : "globe"
        let titleKey = isReady
            ? "onboarding.shortcuts.globeKeyNotice.ready.title"
            : "onboarding.shortcuts.globeKeyNotice.title"
        let messageKey = isReady
            ? "onboarding.shortcuts.globeKeyNotice.ready.message"
            : "onboarding.shortcuts.globeKeyNotice.message"

        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(isDarkMode ? 0.22 : 0.14))
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Text(L(titleKey))
                        .font(.studioDisplay(16, weight: .bold))
                        .foregroundStyle(onboardingPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    if !isReady {
                        StudioButton(
                            title: L("onboarding.shortcuts.globeKeyNotice.button"),
                            systemImage: "arrow.up.forward.app",
                            variant: .secondary,
                        ) {
                            viewModel.openKeyboardSystemSettings()
                        }
                        .fixedSize()
                    }
                }

                Text(L(messageKey))
                    .font(.studioBody(13))
                    .foregroundStyle(onboardingSecondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accent.opacity(isDarkMode ? 0.10 : 0.06)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(isDarkMode ? 0.32 : 0.20), lineWidth: 1),
        )
        .animation(.easeInOut(duration: 0.25), value: isReady)
    }

    @ViewBuilder
    private func hotkeySequence(_ binding: HotkeyBinding) -> some View {
        let keys = HotkeyFormat.components(binding)

        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
            if index > 0 {
                Text("+")
                    .font(.studioBody(12, weight: .semibold))
                    .foregroundStyle(onboardingTertiaryText)
            }

            hotkeyKeycap(key)
        }
    }

    private func hotkeyKeycap(_ key: String) -> some View {
        Text(key.uppercased())
            .font(.studioBody(12, weight: .bold))
            .tracking(key.count > 1 ? 0.8 : 0.2)
            .foregroundStyle(onboardingPrimaryText)
            .padding(.horizontal, key.count > 2 ? 16 : 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(onboardingMutedSurface),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(onboardingSubtleBorder, lineWidth: 1),
            )
    }

    private var footerBar: some View {
        HStack(spacing: 16) {
            if viewModel.canGoBack {
                footerSecondaryButton(
                    title: L("onboarding.action.back"),
                    systemImage: "arrow.left",
                ) {
                    viewModel.goBack()
                }
            }

            Spacer()

            if viewModel.currentStep == .account {
                footerTertiaryButton(title: L("onboarding.account.skip")) {
                    viewModel.continueWithoutCloudAccount()
                }
            } else if viewModel.isSkippable {
                footerTertiaryButton(title: L("onboarding.action.skip")) {
                    viewModel.skip()
                }
            }

            if viewModel.currentStep == .account {
                if authState.isLoggedIn {
                    footerPrimaryButton(title: L("onboarding.action.continue")) {
                        viewModel.useCloudAccountModelsAndContinue()
                    }
                }
            } else {
                footerPrimaryButton(
                    title: viewModel.isLastStep ? L("onboarding.action.getStarted") : L("onboarding.action.continue"),
                ) {
                    viewModel.advance()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(onboardingFooterSurface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(onboardingBorder, lineWidth: 1),
        )
    }

    private func footerPrimaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.studioBody(12, weight: .bold))
                    .tracking(0.8)
                Image(systemName: viewModel.isLastStep ? "arrow.right" : "arrow.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(onboardingPrimaryButtonText)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(StudioTheme.accent),
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(onboardingPrimaryButtonStroke, lineWidth: 1),
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func footerSecondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.studioBody(12, weight: .semibold))
            }
            .foregroundStyle(onboardingPrimaryText)
            .frame(height: 38)
            .padding(.horizontal, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(onboardingMutedSurface),
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(onboardingSubtleBorder, lineWidth: 1),
            )
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func footerTertiaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.studioBody(11, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(onboardingSecondaryText)
                .frame(height: 38)
                .padding(.horizontal, 10)
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func editorialStepHeader(
        eyebrow: String? = nil,
        title: String,
        subtitle: String,
        alignCenter: Bool,
        trailing: AnyView? = nil,
        showStepCounter: Bool = true,
    ) -> some View {
        Group {
            if alignCenter {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .center, spacing: 8) {
                        if let eyebrow, !eyebrow.isEmpty {
                            Text(eyebrow)
                                .font(.studioBody(9, weight: .semibold))
                                .tracking(1.6)
                                .textCase(.uppercase)
                                .foregroundStyle(StudioTheme.accent.opacity(0.92))
                        }

                        Text(title)
                            .font(.studioDisplay(30, weight: .bold))
                            .foregroundStyle(onboardingPrimaryText)
                            .lineLimit(2)

                        Text(subtitle)
                            .font(.studioBody(13))
                            .foregroundStyle(onboardingSecondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    if showStepCounter {
                        stepCounterPill
                    }
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let eyebrow, !eyebrow.isEmpty {
                            Text(eyebrow)
                                .font(.studioBody(9, weight: .semibold))
                                .tracking(1.6)
                                .textCase(.uppercase)
                                .foregroundStyle(StudioTheme.accent.opacity(0.92))
                        }

                        Text(title)
                            .font(.studioDisplay(30, weight: .bold))
                            .foregroundStyle(onboardingPrimaryText)
                            .lineLimit(2)

                        Text(subtitle)
                            .font(.studioBody(13))
                            .foregroundStyle(onboardingSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    HStack(spacing: 10) {
                        trailing
                        if showStepCounter {
                            stepCounterPill
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignCenter ? .center : .leading)
    }

    private var stepCounterPill: some View {
        Text(stepCounterText)
            .font(.studioBody(10, weight: .semibold))
            .foregroundStyle(onboardingTertiaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(onboardingMutedSurface),
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(onboardingSubtleBorder, lineWidth: 1),
            )
    }

    private var onboardingCardFill: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(onboardingCardSurface)
    }

    private var onboardingCardStroke: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(onboardingSubtleBorder, lineWidth: 1)
    }

    private func languageCardFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                isSelected
                    ? onboardingSelectedCardSurface
                    : onboardingCardSurface,
            )
    }

    private func languageCardStroke(isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? onboardingSelectedBorder : onboardingSubtleBorder, lineWidth: 1)

            if isSelected {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(StudioTheme.accent.opacity(0.85), lineWidth: 1.2)
                    .padding(-2)
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var onboardingPrimaryText: Color {
        StudioTheme.textPrimary.opacity(isDarkMode ? 0.96 : 0.98)
    }

    private var onboardingSecondaryText: Color {
        StudioTheme.textSecondary.opacity(isDarkMode ? 0.9 : 0.96)
    }

    private var onboardingTertiaryText: Color {
        StudioTheme.textTertiary.opacity(isDarkMode ? 0.94 : 0.98)
    }

    private var onboardingCardSurface: Color {
        isDarkMode ? Color.white.opacity(0.045) : StudioTheme.surface
    }

    private var onboardingMutedSurface: Color {
        isDarkMode ? Color.white.opacity(0.05) : StudioTheme.surfaceMuted
    }

    private var onboardingSelectedCardSurface: Color {
        isDarkMode
            ? Color(red: 0.23, green: 0.23, blue: 0.25).opacity(0.96)
            : StudioTheme.accentSoft
    }

    private var onboardingBorder: Color {
        isDarkMode ? Color.white.opacity(0.06) : StudioTheme.border.opacity(0.9)
    }

    private var onboardingSubtleBorder: Color {
        isDarkMode ? Color.white.opacity(0.05) : StudioTheme.border
    }

    private var onboardingSelectedBorder: Color {
        isDarkMode ? Color.white.opacity(0.28) : StudioTheme.accent.opacity(0.28)
    }

    private var onboardingFooterSurface: Color {
        isDarkMode
            ? Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.96)
            : Color(red: 0.955, green: 0.958, blue: 0.965)
    }

    private var onboardingPrimaryButtonText: Color {
        isDarkMode ? Color.white.opacity(0.98) : Color.white.opacity(0.96)
    }

    private var onboardingPrimaryButtonStroke: Color {
        isDarkMode ? Color.white.opacity(0.14) : Color.white.opacity(0.22)
    }

    private var shortcutsSectionSpacing: CGFloat {
        14
    }

    private var onboardingSelectionRing: Color {
        isDarkMode ? Color(red: 0.27, green: 0.31, blue: 0.43) : StudioTheme.border
    }

    private var onboardingSelectionCheckmark: Color {
        isDarkMode ? Color.black.opacity(0.78) : Color.white.opacity(0.96)
    }

    private var onboardingProgressTrack: Color {
        isDarkMode ? Color.white.opacity(0.08) : StudioTheme.border.opacity(0.72)
    }

    private var onboardingBadgeFill: Color {
        isDarkMode ? Color.white.opacity(0.04) : StudioTheme.surfaceMuted
    }

    private var onboardingSelectedBadgeFill: Color {
        isDarkMode ? Color.white.opacity(0.08) : StudioTheme.accentSoft
    }

}
