import AppKit
import SwiftUI

// swiftlint:disable file_length type_body_length
struct OnboardingView: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @ObservedObject var viewModel: OnboardingViewModel
    let appearanceMode: AppearanceMode
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var authState = AuthState.shared
    @State private var googleCloudOAuthAuthorized = GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable()
    @State private var isAuthorizingGoogleCloudOAuth = false
    @Environment(\.colorScheme) private var colorScheme

    private let languageColumns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                windowBackdrop

                onboardingCanvas(in: proxy.size)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
        .alert(
            L("onboarding.permissions.incompleteAlert.title"),
            isPresented: $viewModel.showIncompletePermissionsAlert
        ) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("onboarding.permissions.incompleteAlert.message"))
        }
        .alert(
            L("onboarding.shortcuts.replacement.appliedAlert.title"),
            isPresented: $viewModel.showShortcutReplacementAppliedAlert
        ) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(shortcutReplacementAppliedAlertMessage)
        }
        .alert(
            L("onboarding.sttConfig.incompleteAlert.title"),
            isPresented: $viewModel.showIncompleteSTTConfigurationAlert
        ) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("onboarding.sttConfig.incompleteAlert.message"))
        }
        .alert(
            L("onboarding.llmConfig.incompleteAlert.title"),
            isPresented: $viewModel.showIncompleteLLMConfigurationAlert
        ) {
            Button(L("onboarding.llmConfig.incompleteAlert.skip"), role: .cancel) {
                viewModel.skipIncompleteLLMConfiguration()
            }
            Button(L("onboarding.llmConfig.incompleteAlert.continueConfig")) {}
        } message: {
            Text(L("onboarding.llmConfig.incompleteAlert.message"))
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
        TypefluxColor.contentBackground.color.ignoresSafeArea()
    }

    private func onboardingCanvas(in size: CGSize) -> some View {
        TypefluxForm {
            Section { stepContent(in: size) }
        }
        .safeAreaInset(edge: .bottom) { footerBar.padding(12) }
        .toolbar {
            ToolbarItem(id: "typeflux.window.title", placement: .principal) {
                Text(stepTitle).font(.headline).accessibilityAddTraits(.isHeader)
            }
        }
        .typefluxWindowChrome(title: stepTitle)
    }

    private var stepTitle: String {
        switch viewModel.currentStep {
        case .language: L("onboarding.language.title")
        case .account: L("onboarding.account.title")
        case .stt: L("onboarding.models.stt.title")
        case .llm: L("onboarding.models.llm.title")
        case .permissions: L("onboarding.permissions.title")
        case .shortcuts: L("onboarding.shortcuts.title")
        }
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

    private func languageStep(contentHeight _: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: TypefluxSpacing.section.value(for: interfaceStyle)) {
            editorialStepHeader(
                title: L("onboarding.language.title"),
                subtitle: L("onboarding.language.subtitle"),
                alignCenter: false
            )

            TypefluxRadioGroup(L("onboarding.language.title"),
                               selection: Binding(get: { viewModel.appLanguage }, set: viewModel.setLanguage)) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName)
                        .accessibilityLabel(Text(language.displayName))
                        .accessibilityIdentifier("onboarding.language.\(language.rawValue)")
                        .tag(language)
                }
            }
            .accessibilityIdentifier("onboarding.language")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        showStepCounter: false
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
                        .font(.system(.largeTitle))
                        .foregroundStyle(TypefluxColor.accent.color)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(authState.userProfile?.resolvedDisplayName ?? L("provider.llm.typefluxCloud"))
                            .font(.system(.title2, weight: .bold))
                            .foregroundStyle(onboardingPrimaryText)
                        Text(authState.userProfile?.email ?? L("onboarding.account.subtitle"))
                            .font(.system(.callout))
                            .foregroundStyle(onboardingSecondaryText)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(.body))
                        .foregroundStyle(TypefluxColor.accent.color)
                    Text(L("onboarding.account.cloudReady"))
                        .font(.system(.callout))
                        .foregroundStyle(onboardingSecondaryText)
                }
            }
        }
    }

    private var sttStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            editorialStepHeader(
                eyebrow: "Step 03",
                title: L("onboarding.models.stt.title"),
                subtitle: L("onboarding.sttProvider.subtitle"),
                alignCenter: false
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
                            isSelected: viewModel.sttProvider == provider
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.selectSTTProvider(provider)
                            }
                        }
                    }
                }
                .frame(width: 280)

                sttConfigPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .alert(L("settings.shortcuts.auxiliaryConflict"), isPresented: $viewModel.shortcutReplacementConflict) {
            Button(L("common.ok"), role: .cancel) {}
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
                    .fill(TypefluxColor.accent.color)
                    .frame(width: 140 * progress, height: 4)
            }

            Text(label)
                .font(.system(.footnote, weight: .semibold))
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
        case .soniox:
            sonioxConfigFields
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
                alignCenter: false
            )

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    let standardOptions = (
                        LLMRemoteProvider.settingsDisplayOrder
                            .filter { $0 != .typefluxCloud && $0 != .custom }
                            .filter { $0 != .freeModel || !FreeLLMModelRegistry.suggestedModelNames.isEmpty }
                            .map { provider in
                                (
                                    title: provider.displayName,
                                    providerID: provider.studioProviderID,
                                    remoteProvider: Optional(provider)
                                )
                            } + [
                                (
                                    title: LLMProvider.ollama.displayName,
                                    providerID: StudioModelProviderID.ollama,
                                    remoteProvider: nil
                                )
                            ]
                    ).sorted { lhs, rhs in
                        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }

                    ForEach(standardOptions, id: \.providerID) { option in
                        if let provider = option.remoteProvider {
                            let isSelected = viewModel.llmProvider == .openAICompatible
                                && viewModel.llmRemoteProvider == provider
                            modelProviderCard(
                                providerID: provider.studioProviderID,
                                title: provider.displayName,
                                description: L("settings.models.card.\(provider.rawValue).summary"),
                                badge: provider == .freeModel
                                    ? L("settings.models.badge.free")
                                    : (
                                        provider.apiStyle == .openAICompatible
                                            ? L("settings.models.badge.api")
                                            : L("settings.models.badge.native")
                                    ),
                                isSelected: isSelected
                            ) {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    viewModel.selectLLMRemoteProvider(provider)
                                }
                            }
                        } else {
                            modelProviderCard(
                                providerID: .ollama,
                                title: L("provider.llm.ollama"),
                                description: L("settings.models.card.ollama.summary"),
                                badge: L("settings.models.badge.local"),
                                isSelected: viewModel.llmProvider == .ollama
                            ) {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    viewModel.selectOllama()
                                }
                            }
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
                            isSelected: isSelected
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.selectLLMRemoteProvider(provider)
                            }
                        }
                    }
                }
                .frame(width: 280)

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
                    suggestions: OpenAIAudioModelCatalog.whisperEndpoints
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.whisperAPIKey,
                    secure: true
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.defaultWhisperModel(
                        forEndpoint: viewModel.whisperBaseURL
                    ),
                    text: $viewModel.whisperModel,
                    suggestions: OpenAIAudioModelCatalog.suggestedWhisperModels(
                        forEndpoint: viewModel.whisperBaseURL
                    )
                )
            }
        }
    }

    private var freeSTTConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                if FreeSTTModelRegistry.suggestedModelNames.isEmpty {
                    Text(L("settings.models.freeSTT.noSources"))
                        .font(.system(.callout))
                        .foregroundStyle(onboardingSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    StudioMenuPicker(
                        options: FreeSTTModelRegistry.suggestedModelNames.map { ($0, $0) },
                        selection: $viewModel.freeSTTModel,
                        width: 320
                    )
                }

                Text(L("settings.models.freeSTT.hint"))
                    .font(.system(.callout))
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
                    viewModel.selectLocalSTTModel(model)
                } label: {
                    HStack(spacing: 14) {
                        languageSelectionIndicator(isSelected: isSelected)
                            .scaleEffect(0.78)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(onboardingPrimaryText)

                                if let recommendationBadgeTitle = model.recommendationBadgeTitle {
                                    onboardingRecommendationPill(recommendationBadgeTitle)
                                }
                            }

                            Text(model.specs.summary)
                                .font(.system(.callout))
                                .foregroundStyle(onboardingSecondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(model.specs.sizeValue)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(isSelected ? TypefluxColor.accent.color
                                .opacity(0.92) : onboardingTertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? onboardingSelectedBadgeFill : onboardingBadgeFill)
                            )
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(languageCardFill(isSelected: isSelected))
                    .overlay(languageCardStroke(isSelected: isSelected))
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(.callout))
                    .foregroundStyle(onboardingTertiaryText)
                Text(L("onboarding.models.stt.local.hint"))
                    .font(.system(.callout))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    private func onboardingRecommendationPill(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, weight: .bold))
            .foregroundStyle(Color.green.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.green.opacity(0.16))
            )
    }

    private var multimodalLLMConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioSuggestedTextInputCard(
                    label: L("settings.models.remote.baseURL"),
                    placeholder: OpenAIAudioModelCatalog.multimodalEndpoints[0],
                    text: $viewModel.multimodalLLMBaseURL,
                    suggestions: OpenAIAudioModelCatalog.multimodalEndpoints
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.multimodalLLMAPIKey,
                    secure: true
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.multimodalModels[0],
                    text: $viewModel.multimodalLLMModel,
                    suggestions: OpenAIAudioModelCatalog.multimodalModels
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
                    secure: true
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
                    text: $viewModel.doubaoAppID
                )
                StudioTextInputCard(
                    label: L("settings.models.doubao.resourceID"),
                    placeholder: DoubaoASRDefaults.resourceID,
                    text: $viewModel.doubaoResourceID
                )
                StudioTextInputCard(
                    label: L("settings.models.doubao.accessToken"),
                    placeholder: "",
                    text: $viewModel.doubaoAccessToken,
                    secure: true
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
                    text: $viewModel.googleCloudProjectID
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: GoogleCloudSpeechDefaults.model,
                    text: $viewModel.googleCloudModel,
                    suggestions: GoogleCloudSpeechDefaults.suggestedModels
                )
                HStack(spacing: 12) {
                    OnboardingActionButton(
                        title: googleCloudOAuthAuthorized
                            ? L("settings.models.googleCloud.oauth.reauthorize")
                            : L("settings.models.googleCloud.oauth.authorize"),
                        systemImage: "person.crop.circle.badge.checkmark",
                        kind: .regular,
                        isDisabled: AppServerConfiguration.googleCloudOAuthClientID
                            .isEmpty || isAuthorizingGoogleCloudOAuth,
                        isLoading: isAuthorizingGoogleCloudOAuth
                    ) {
                        authorizeGoogleCloudFromOnboarding()
                    }

                    if googleCloudOAuthAuthorized {
                        OnboardingActionButton(
                            title: L("settings.models.googleCloud.oauth.disconnect"),
                            systemImage: "xmark.circle",
                            kind: .borderless
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
                        ? nil : AppServerConfiguration.googleCloudOAuthClientSecret
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
                    secure: true
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: OpenAIAudioModelCatalog.groqWhisperModels[0],
                    text: $viewModel.groqSTTModel,
                    suggestions: OpenAIAudioModelCatalog.groqWhisperModels
                )
            }
        }
    }

    private var sonioxConfigFields: some View {
        onboardingConfigCard {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.sonioxAPIKey,
                    secure: true
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: SonioxASRDefaults.model,
                    text: $viewModel.sonioxModel,
                    suggestions: SonioxASRDefaults.suggestedModels
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
                                    .font(.system(.callout))
                                    .foregroundStyle(Color.white.opacity(0.48))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                StudioMenuPicker(
                                    options: FreeLLMModelRegistry.suggestedModelNames.map { ($0, $0) },
                                    selection: $viewModel.llmModel,
                                    width: 320
                                )
                            }
                            Text(L("settings.models.freeModel.hint"))
                                .font(.system(.callout))
                                .foregroundStyle(Color.white.opacity(0.48))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            StudioTextInputCard(
                                label: L("common.apiKey"),
                                placeholder: provider == .gemini ? "AIza..." : "sk-...",
                                text: $viewModel.llmAPIKey,
                                secure: true
                            )
                            StudioSuggestedTextInputCard(
                                label: L("settings.models.remote.baseURL"),
                                placeholder: provider.defaultBaseURL.isEmpty
                                    ? "https://api.openai.com/v1" : provider.defaultBaseURL,
                                text: $viewModel.llmBaseURL,
                                suggestions: endpointSuggestions
                            )
                            StudioSuggestedTextInputCard(
                                label: L("common.model"),
                                placeholder: provider.defaultModel,
                                text: $viewModel.llmModel,
                                suggestions: modelSuggestions
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
                        .filter { !$0.isEmpty }
                )
                StudioSuggestedTextInputCard(
                    label: L("common.model"),
                    placeholder: "qwen2.5:7b",
                    text: $viewModel.ollamaModel,
                    suggestions: [viewModel.ollamaModel, "qwen2.5:7b", "llama3.2:3b", "gemma3:4b"]
                        .filter { !$0.isEmpty }
                )
            }
        }
    }

    private func onboardingConfigCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .background(TypefluxColor.controlBackground.color)
    }

    private var sttConfigPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.system(.footnote, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(onboardingTertiaryText)

            Text(viewModel.sttProvider.displayName)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(onboardingPrimaryText)

            Text(sttProviderDescription(viewModel.sttProvider))
                .font(.system(.callout))
                .foregroundStyle(onboardingSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if sttProviderNeedsConfiguration(viewModel.sttProvider) {
                    sttInlineConfig(for: viewModel.sttProvider)
                } else {
                    onboardingConfigCard {
                        Text("This provider is ready to use with the current defaults.")
                            .font(.system(.callout))
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
                                    .font(.system(.subheadline, weight: .semibold))
                                Text(L("onboarding.models.getAPIKey"))
                                    .font(.system(.callout, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(.footnote, weight: .semibold))
                            }
                            .foregroundStyle(TypefluxColor.accent.color)
                        }
                    }

                    Spacer()

                    OnboardingActionButton(
                        title: viewModel.sttConnectionTestState == .testing
                            ? L("settings.models.testingConnection") : L("settings.models.testConnection"),
                        systemImage: viewModel.sttConnectionTestState == .testing ? nil : "network",
                        kind: .regular,
                        isDisabled: viewModel.sttConnectionTestState == .testing,
                        isLoading: viewModel.sttConnectionTestState == .testing
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
                .font(.system(.footnote, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(onboardingTertiaryText)

            Text(viewModel.llmProvider == .ollama ? L("provider.llm.ollama") : viewModel.llmRemoteProvider.displayName)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(onboardingPrimaryText)

            Text(viewModel.llmProvider == .ollama
                ? L("settings.models.card.ollama.summary")
                : L("settings.models.card.\(viewModel.llmRemoteProvider.rawValue).summary"))
                .font(.system(.callout))
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
                       viewModel.llmProvider != .ollama {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Image(systemName: "key")
                                    .font(.system(.subheadline, weight: .semibold))
                                Text(L("onboarding.models.getAPIKey"))
                                    .font(.system(.callout, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(.footnote, weight: .semibold))
                            }
                            .foregroundStyle(TypefluxColor.accent.color)
                        }
                    }

                    Spacer()

                    OnboardingActionButton(
                        title: viewModel.llmConnectionTestState == .testing
                            ? L("settings.models.testingConnection") : L("settings.models.testConnection"),
                        systemImage: viewModel.llmConnectionTestState == .testing ? nil : "network",
                        kind: .regular,
                        isDisabled: viewModel.llmConnectionTestState == .testing,
                        isLoading: viewModel.llmConnectionTestState == .testing
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
        case .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime, .googleCloud, .groq, .soniox, .freeModel:
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
        case .soniox:
            URL(string: "https://console.soniox.com/")
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
        case .openCodeZen:
            URL(string: "https://opencode.ai/auth")
        case .openCodeGo:
            URL(string: "https://opencode.ai/auth")
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
                        .foregroundStyle(TypefluxColor.success.color)
                        .font(.system(.body))
                    Text(L("settings.models.connectionSuccess", totalMs, totalMs))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(TypefluxColor.success.color)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(.subheadline))
                        .foregroundStyle(onboardingSecondaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(
                                cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                style: .continuous
                            )
                            .fill(onboardingMutedSurface)
                        )
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                style: .continuous
                            )
                            .stroke(onboardingSubtleBorder, lineWidth: 1)
                        )
                }
            }
        case let .notice(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(onboardingSecondaryText)
                    .font(.system(.body))
                Text(message)
                    .font(.system(.callout))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .failure(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(TypefluxColor.danger.color)
                    .font(.system(.body))
                Text(message)
                    .font(.system(.callout))
                    .foregroundStyle(TypefluxColor.danger.color)
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
        case .soniox: .soniox
        case .appleSpeech: .appleSpeech
        case .typefluxOfficial: .typefluxOfficial
        }
    }

    private func loadProviderLogo(for providerID: StudioModelProviderID) -> NSImage? {
        guard let name = providerLogoResourceName(for: providerID) else { return nil }
        let url = Bundle.appResources.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Resources/Providers"
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
        case .openCodeZen, .openCodeGo: "opencode"
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
        case .openCodeZen: "sparkle.magnifyingglass"
        case .openCodeGo: "hare"
        case .multimodalLLM: "brain.filled.head.profile"
        case .aliCloud: "antenna.radiowaves.left.and.right"
        case .doubaoRealtime: "bolt.horizontal.circle"
        case .soniox: "waveform.and.mic"
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
        case .soniox: L("settings.models.card.soniox.summary")
        case .appleSpeech: ""
        case .typefluxOfficial: L("settings.models.card.typefluxOfficial.summary")
        }
    }

    private func modelProviderCard(providerID: StudioModelProviderID, title: String, description: String,
                                   badge: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        TypefluxButton(kind: isSelected ? .primary : .regular, action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body)
                    Text(description).font(.subheadline).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(title)
        .accessibilityHint(description + " · " + badge)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func providerIconBadge(for providerID: StudioModelProviderID, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .fill(LegacyStudioPalette.modelProviderIconPlate)
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .stroke(providerIconBadgeBorder(isSelected: isSelected), lineWidth: 1)
            )
            .overlay(
                Group {
                    if providerID.usesTypefluxBranding {
                        TypefluxLogoBadge(
                            size: 30,
                            symbolSize: 15,
                            backgroundShape: .circle,
                            showsBorder: true
                        )
                    } else if let image = loadProviderLogo(for: providerID) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(providerID.usesExpandedLogo ? 1 : 6)
                    } else {
                        Image(systemName: providerSymbol(for: providerID))
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(
                                isSelected ? TypefluxColor.accent.color : LegacyStudioPalette
                                    .modelProviderFallbackSymbol
                            )
                    }
                }
            )
    }

    private func providerIconBadgeBorder(isSelected: Bool) -> Color {
        isSelected ? TypefluxColor.accent.color.opacity(0.55) : Color.black.opacity(0.12)
    }

    private func permissionsStep(contentHeight: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                editorialStepHeader(
                    title: L("onboarding.permissions.title"),
                    subtitle: L("onboarding.permissions.subtitle"),
                    alignCenter: false
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
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .fill(isGranted ? onboardingSelectedBadgeFill : onboardingMutedSurface)
                    .frame(width: 38, height: 38)
                Image(systemName: permissionIcon(snapshot.id))
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(isGranted ? TypefluxColor.success.color : TypefluxColor.accent.color.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(onboardingPrimaryText)
                Text(snapshot.detail)
                    .font(.system(.subheadline))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isGranted {
                Text(snapshot.badgeText)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(TypefluxColor.success.color.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TypefluxColor.success.color.opacity(0.12))
                    )
            } else {
                OnboardingActionButton(
                    title: snapshot.actionTitle,
                    systemImage: "lock.open.display",
                    kind: .primary,
                    isDisabled: isRequesting,
                    isLoading: isRequesting
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
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(TypefluxColor.accent.color)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                        .fill(TypefluxColor.accent.color.opacity(isDarkMode ? 0.16 : 0.10))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(L("onboarding.permissions.instruction.title"))
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(onboardingPrimaryText)
                Text(L("onboarding.permissions.instruction.subtitle"))
                    .font(.system(.callout))
                    .foregroundStyle(onboardingSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .fill(onboardingMutedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .stroke(onboardingSubtleBorder, lineWidth: 1)
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
                alignCenter: false
            )

            VStack(spacing: shortcutsSectionSpacing) {
                HStack(alignment: .top, spacing: shortcutsSectionSpacing) {
                    shortcutCard(
                        title: L("settings.shortcuts.activation.title"),
                        subtitle: L("onboarding.shortcuts.activation.hint"),
                        binding: viewModel.activationHotkey,
                        expanded: true
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        if let binding = viewModel.auxiliaryHotkey {
                            shortcutCard(
                                title: L("settings.shortcuts.auxiliary.title"),
                                subtitle: L("onboarding.shortcuts.auxiliary.hint"),
                                binding: binding,
                                expanded: true
                            )
                        } else {
                            Text(L("settings.shortcuts.auxiliary.title"))
                            Text(L("onboarding.shortcuts.auxiliary.unset"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: shortcutsSectionSpacing) {
                    shortcutCard(
                        title: L("settings.shortcuts.persona.title"),
                        subtitle: L("onboarding.shortcuts.persona.hint"),
                        binding: HotkeyBinding.defaultPersona,
                        expanded: true
                    )

                    shortcutCard(
                        title: L("settings.shortcuts.history.title"),
                        subtitle: L("onboarding.shortcuts.history.hint"),
                        binding: viewModel.historyHotkey,
                        expanded: true
                    )
                }
            }

            shortcutCard(
                title: L("settings.shortcuts.ask.title"),
                subtitle: L("onboarding.shortcuts.ask.hint"),
                binding: viewModel.askHotkey ?? .defaultAsk,
                expanded: true
            )

            if viewModel.externalKeyboardShortcutReplacement == nil {
                externalKeyboardShortcutNotice
                globeKeyNotice
            } else {
                shortcutReplacementNotice
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func shortcutCard(
        title: String,
        subtitle: String,
        binding: HotkeyBinding,
        expanded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(onboardingPrimaryText)
                    .lineLimit(1)

                Spacer()

                hotkeySequence(binding)
                    .fixedSize()
            }

            Text(subtitle)
                .font(.system(.callout))
                .foregroundStyle(onboardingSecondaryText)
                .lineLimit(expanded ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: expanded ? .infinity : nil, minHeight: 96, alignment: .topLeading)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private var globeKeyNotice: some View {
        let isReady = viewModel.isGlobeKeyReady
        let accent: Color = isReady ? TypefluxColor.success.color : TypefluxColor.warning.color
        let titleKey = isReady
            ? "onboarding.shortcuts.globeKeyNotice.ready.title"
            : "onboarding.shortcuts.globeKeyNotice.title"
        let messageKey = isReady
            ? "onboarding.shortcuts.globeKeyNotice.ready.message"
            : "onboarding.shortcuts.globeKeyNotice.message"

        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .fill(accent.opacity(isDarkMode ? 0.22 : 0.14))
                if isReady {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(.title2, weight: .semibold))
                        .foregroundStyle(accent)
                } else {
                    VStack(spacing: 2) {
                        Text("FN")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(accent)
                        Image(systemName: "globe")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Text(L(titleKey))
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(onboardingPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    if !isReady {
                        OnboardingActionButton(
                            title: L("onboarding.shortcuts.globeKeyNotice.button"),
                            systemImage: "arrow.up.forward.app",
                            kind: .regular
                        ) {
                            viewModel.openKeyboardSystemSettings()
                        }
                        .fixedSize()
                    }
                }

                Text(L(messageKey))
                    .font(.system(.body))
                    .foregroundStyle(onboardingSecondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .fill(accent.opacity(isDarkMode ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .stroke(accent.opacity(isDarkMode ? 0.32 : 0.20), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: isReady)
    }

    private var externalKeyboardShortcutNotice: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .fill(TypefluxColor.accent.color.opacity(isDarkMode ? 0.22 : 0.12))
                Image(systemName: "keyboard")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(TypefluxColor.accent.color)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 12) {
                Text(L("onboarding.shortcuts.externalKeyboard.title"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(onboardingPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("onboarding.shortcuts.externalKeyboard.message") + "\n" +
                    L("onboarding.shortcuts.auxiliary.externalKeyboard"))
                    .font(.system(.body))
                    .foregroundStyle(onboardingSecondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    externalKeyboardReplacementButton(.rightCommand)
                    externalKeyboardReplacementButton(.rightOption)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .fill(TypefluxColor.accent.color.opacity(isDarkMode ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .stroke(TypefluxColor.accent.color.opacity(isDarkMode ? 0.28 : 0.18), lineWidth: 1)
        )
    }

    private var shortcutReplacementNotice: some View {
        let replacementName = shortcutReplacementName(viewModel.externalKeyboardShortcutReplacement)

        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .fill(TypefluxColor.success.color.opacity(isDarkMode ? 0.22 : 0.14))
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(TypefluxColor.success.color)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Text(String(format: L("onboarding.shortcuts.replacement.active.title"), replacementName))
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(onboardingPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    OnboardingActionButton(
                        title: L("onboarding.shortcuts.replacement.restore"),
                        systemImage: "arrow.uturn.backward",
                        kind: .regular
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.restoreDefaultFNShortcuts()
                        }
                    }
                    .fixedSize()
                }

                Text(
                    String(
                        format: L("onboarding.shortcuts.replacement.active.message"),
                        replacementName,
                        replacementName
                    )
                )
                .font(.system(.body))
                .foregroundStyle(onboardingSecondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .fill(TypefluxColor.success.color.opacity(isDarkMode ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .stroke(TypefluxColor.success.color.opacity(isDarkMode ? 0.32 : 0.20), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: viewModel.externalKeyboardShortcutReplacement)
    }

    private func externalKeyboardReplacementButton(
        _ replacement: OnboardingViewModel.ExternalKeyboardShortcutReplacement
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.useExternalKeyboardShortcutReplacement(replacement)
            }
        } label: {
            HStack(spacing: 10) {
                Text(shortcutReplacementKeycap(replacement))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(TypefluxColor.accent.color)
                    .frame(width: 54, alignment: .center)

                Rectangle()
                    .fill(onboardingSubtleBorder)
                    .frame(width: 1, height: 20)

                Text(shortcutReplacementButtonTitle(replacement))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(onboardingPrimaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .fill(onboardingCardSurface)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                            style: .continuous
                        )
                        .stroke(TypefluxColor.accent.color.opacity(isDarkMode ? 0.26 : 0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.bordered)
    }

    private var shortcutReplacementAppliedAlertMessage: String {
        let auxiliaryMessage = viewModel.auxiliaryHotkey.map {
            L("onboarding.shortcuts.auxiliary.active", HotkeyFormat.display($0))
        } ?? L("onboarding.shortcuts.auxiliary.unset")
        if let replacement = viewModel.externalKeyboardShortcutReplacement {
            return String(
                format: L("onboarding.shortcuts.replacement.appliedAlert.message"),
                shortcutReplacementName(replacement),
                shortcutReplacementName(replacement)
            ) + "\n\n" + auxiliaryMessage
        }
        return L("onboarding.shortcuts.replacement.restoredAlert.message") + "\n\n" + auxiliaryMessage
    }

    private func shortcutReplacementName(
        _ replacement: OnboardingViewModel.ExternalKeyboardShortcutReplacement?
    ) -> String {
        switch replacement {
        case .rightCommand:
            L("onboarding.shortcuts.replacement.rightCommand")
        case .rightOption:
            L("onboarding.shortcuts.replacement.rightOption")
        case nil:
            L("onboarding.shortcuts.replacement.fn")
        }
    }

    private func shortcutReplacementButtonTitle(
        _ replacement: OnboardingViewModel.ExternalKeyboardShortcutReplacement
    ) -> String {
        switch replacement {
        case .rightCommand:
            L("onboarding.shortcuts.externalKeyboard.useRightCommand")
        case .rightOption:
            L("onboarding.shortcuts.externalKeyboard.useRightOption")
        }
    }

    private func shortcutReplacementKeycap(
        _ replacement: OnboardingViewModel.ExternalKeyboardShortcutReplacement
    ) -> String {
        switch replacement {
        case .rightCommand:
            "⌘(R)"
        case .rightOption:
            "⌥(R)"
        }
    }

    @ViewBuilder
    private func hotkeySequence(_ binding: HotkeyBinding) -> some View {
        let keys = HotkeyFormat.components(binding)
        let pressCount = HotkeyFormat.pressCount(binding)

        HStack(spacing: 5) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("+")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(onboardingTertiaryText)
                    }

                    hotkeyKeycap(key)
                }
            }

            if let pressCount {
                Text("×\(pressCount)")
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(onboardingSecondaryText)
                    .baselineOffset(1)
            }
        }
        .help(binding.isModifierDoubleTapTrigger ? L("settings.shortcuts.doubleTapHelp") : "")
    }

    private func hotkeyKeycap(_ key: String) -> some View {
        Text(key.uppercased())
            .font(.system(.callout, weight: .bold))
            .tracking(key.count > 1 ? 0.8 : 0.2)
            .foregroundStyle(onboardingPrimaryText)
            .padding(.horizontal, key.count > 2 ? 16 : 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .fill(onboardingMutedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .stroke(onboardingSubtleBorder, lineWidth: 1)
            )
    }

    private var footerBar: some View {
        TypefluxGlassContainer(radius: .popover, placement: .inWindow) {
            HStack(spacing: 16) {
                if viewModel.canGoBack {
                    footerSecondaryButton(
                        title: L("onboarding.action.back"),
                        systemImage: "arrow.left"
                    ) {
                        viewModel.goBack()
                    }
                }

                Spacer()

                if viewModel.currentStep == .account {
                    footerTertiaryButton(
                        title: L("onboarding.account.skip"),
                        foregroundColor: onboardingAccountSkipText
                    ) {
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
                        title: viewModel
                            .isLastStep ? L("onboarding.action.getStarted") : L("onboarding.action.continue")
                    ) {
                        viewModel.advance()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func footerPrimaryButton(title: String, action: @escaping () -> Void) -> some View {
        TypefluxButton(title, kind: .primary, size: .large, defaultAction: true, action: action)
    }

    private func footerSecondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        TypefluxButton(size: .large, action: action) { Label(title, systemImage: systemImage) }
    }

    private func footerTertiaryButton(title: String, foregroundColor: Color? = nil,
                                      action: @escaping () -> Void) -> some View {
        TypefluxButton(title, kind: .borderless, action: action)
            .foregroundStyle(foregroundColor ?? TypefluxColor.secondaryLabel.color)
    }

    private func editorialStepHeader(eyebrow: String? = nil, title: String, subtitle: String,
                                     alignCenter: Bool, trailing: AnyView? = nil,
                                     showStepCounter: Bool = true) -> some View {
        HStack {
            Text(subtitle).font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .fixedSize(horizontal: false, vertical: true)
            if let trailing { trailing }
        }.frame(maxWidth: .infinity, alignment: alignCenter ? .center : .leading)
    }

    private var onboardingCardFill: some View {
        RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .fill(TypefluxColor.contentBackground.color)
    }

    private var onboardingCardStroke: some View {
        RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color)
    }

    private func languageSelectionIndicator(isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? TypefluxColor.accent.color : .clear)
            .overlay {
                Circle().strokeBorder(isSelected ? TypefluxColor.accent.color : TypefluxColor.separator.color)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(nsColor: .selectedControlTextColor))
                }
            }
            .frame(width: TypefluxSpacing.section.value(for: interfaceStyle),
                   height: TypefluxSpacing.section.value(for: interfaceStyle))
            .accessibilityHidden(true)
    }

    private func languageCardFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
            .fill(
                isSelected
                    ? onboardingSelectedCardSurface
                    : onboardingCardSurface
            )
    }

    private func languageCardStroke(isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                .stroke(isSelected ? onboardingSelectedBorder : onboardingSubtleBorder, lineWidth: 1)

            if isSelected {
                RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
                    .stroke(TypefluxColor.accent.color.opacity(0.85), lineWidth: 1.2)
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
        TypefluxColor.label.color
    }

    private var onboardingSecondaryText: Color {
        TypefluxColor.secondaryLabel.color
    }

    private var onboardingTertiaryText: Color {
        TypefluxColor.tertiaryLabel.color
    }

    private var onboardingAccountSkipText: Color {
        TypefluxColor.tertiaryLabel.color.opacity(isDarkMode ? 0.56 : 0.62)
    }

    private var onboardingCardSurface: Color {
        TypefluxColor.controlBackground.color
    }

    private var onboardingMutedSurface: Color {
        TypefluxColor.controlBackground.color
    }

    private var onboardingSelectedCardSurface: Color {
        isDarkMode
            ? Color(red: 0.23, green: 0.23, blue: 0.25).opacity(0.96)
            : TypefluxColor.accent.color.opacity(0.12)
    }

    private var onboardingBorder: Color {
        TypefluxColor.separator.color
    }

    private var onboardingSubtleBorder: Color {
        TypefluxColor.separator.color
    }

    private var onboardingSelectedBorder: Color {
        isDarkMode ? Color.white.opacity(0.28) : TypefluxColor.accent.color.opacity(0.28)
    }

    private var onboardingFooterSurface: Color {
        TypefluxColor.windowBackground.color
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
        isDarkMode ? Color(red: 0.27, green: 0.31, blue: 0.43) : TypefluxColor.separator.color
    }

    private var onboardingSelectionCheckmark: Color {
        isDarkMode ? Color.black.opacity(0.78) : Color.white.opacity(0.96)
    }

    private var onboardingProgressTrack: Color {
        isDarkMode ? Color.white.opacity(0.08) : TypefluxColor.separator.color.opacity(0.72)
    }

    private var onboardingBadgeFill: Color {
        isDarkMode ? Color.white.opacity(0.04) : TypefluxColor.controlBackground.color
    }

    private var onboardingSelectedBadgeFill: Color {
        isDarkMode ? Color.white.opacity(0.08) : TypefluxColor.accent.color.opacity(0.12)
    }
}
