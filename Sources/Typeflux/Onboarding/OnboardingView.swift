import AppKit
import SwiftUI

// swiftlint:disable file_length
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject private var localization = AppLocalization.shared

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
        .preferredColorScheme(.dark)
        .environment(\.locale, localization.locale)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if viewModel.currentStep == .permissions {
                viewModel.refreshPermissions()
            }
        }
    }

    private var windowBackdrop: some View {
        ZStack {
            Color(red: 0.075, green: 0.075, blue: 0.08)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(red: 0.085, green: 0.085, blue: 0.095),
                    Color(red: 0.06, green: 0.06, blue: 0.07),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color(red: 0.13, green: 0.18, blue: 0.34).opacity(0.16),
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
                    stepContent
                        .padding(.horizontal, horizontalPadding(for: size.width))
                        .padding(.top, 18)
                        .padding(.bottom, 110)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollDisabled(viewModel.currentStep == .welcome)
            }

            footerBar
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
        case .welcome:
            "Introduction"
        case .language:
            "Language"
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
            1_030
        case .welcome:
            1_030
        case .permissions:
            940
        case .stt, .llm:
            1_040
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .welcome:
            welcomeStep
        case .language:
            languageStep
        case .stt:
            sttStep
        case .llm:
            llmStep
        case .permissions:
            permissionsStep
        case .shortcuts:
            shortcutsStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 12) {
                appIconBadge(size: 84, iconSize: 54)

                Text(L("sidebar.appName"))
                    .font(.studioDisplay(38, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))

                Text(L("onboarding.welcome.tagline"))
                    .font(.studioBody(15))
                    .foregroundStyle(Color.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                welcomeFeatureCard(
                    icon: "mic.fill",
                    accent: StudioTheme.accent,
                    title: L("onboarding.welcome.feature1.title"),
                    desc: L("onboarding.welcome.feature1.desc"),
                )
                welcomeFeatureCard(
                    icon: "sparkles",
                    accent: Color(red: 0.90, green: 0.66, blue: 0.38),
                    title: L("onboarding.welcome.feature3.title"),
                    desc: L("onboarding.welcome.feature3.desc"),
                )
                welcomeFeatureCard(
                    icon: "square.stack.3d.down.right.fill",
                    accent: Color(red: 0.67, green: 0.75, blue: 1.00),
                    title: L("onboarding.welcome.feature2.title"),
                    desc: L("onboarding.welcome.feature2.desc"),
                )
            }
            .padding(.top, 26)

            Spacer(minLength: 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    private func welcomeFeatureCard(icon: String, accent: Color, title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.studioBody(14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(desc)
                    .font(.studioBody(11))
                    .foregroundStyle(Color.white.opacity(0.54))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(18)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private func appIconBadge(size: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1),
                )

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous))
        }
        .shadow(color: .black.opacity(0.26), radius: 20, x: 0, y: 10)
    }

    private var languageStep: some View {
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

            Spacer(minLength: 20)
        }
        .frame(maxWidth: 740, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func languageCard(_ language: AppLanguage) -> some View {
        let isSelected = viewModel.appLanguage == language

        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                viewModel.setLanguage(language)
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(languageRegionLabel(language))
                        .font(.studioBody(9, weight: .semibold))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(isSelected ? StudioTheme.accent.opacity(0.92) : Color.white.opacity(0.4))

                    Text(languageNativeName(language))
                        .font(.studioDisplay(15, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                }

                Spacer()

                languageSelectionIndicator(isSelected: isSelected)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(languageCardFill(isSelected: isSelected))
            .overlay(languageCardStroke(isSelected: isSelected))
            .shadow(color: isSelected ? StudioTheme.accent.opacity(0.16) : .clear, radius: 20, x: 0, y: 10)
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func languageSelectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? StudioTheme.accent.opacity(0.32) : Color(red: 0.27, green: 0.31, blue: 0.43), lineWidth: 1)
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
                    .foregroundStyle(Color.black.opacity(0.78))
            }
        }
    }

    private func languageRegionLabel(_ language: AppLanguage) -> String {
        switch language {
        case .english:
            "United States / Global"
        case .simplifiedChinese:
            "Mainland China"
        case .traditionalChinese:
            "Taiwan / Hong Kong"
        case .japanese:
            "Japan"
        case .korean:
            "South Korea"
        }
    }

    private func languageNativeName(_ language: AppLanguage) -> String {
        switch language {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
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
                    ForEach(STTProvider.settingsDisplayOrder, id: \.self) { provider in
                        modelProviderCard(
                            providerID: sttProviderToID(provider),
                            title: provider.displayName,
                            description: sttProviderDescription(provider),
                            badge: sttProviderBadge(provider),
                            isSelected: viewModel.sttProvider == provider,
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.sttProvider = provider
                            }
                        }
                    }
                }
                .frame(width: 430)

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
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 140, height: 4)
                Capsule(style: .continuous)
                    .fill(StudioTheme.accent)
                    .frame(width: 140 * progress, height: 4)
            }

            Text(label)
                .font(.studioBody(10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.42))
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
        case .groq:
            groqSTTConfigFields
        case .appleSpeech:
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
                    ForEach(LLMRemoteProvider.settingsDisplayOrder.prefix(1), id: \.self) { provider in
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

                    ForEach(LLMRemoteProvider.settingsDisplayOrder.dropFirst(), id: \.self) { provider in
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
                }
                .frame(width: 430)

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
                        .foregroundStyle(Color.white.opacity(0.48))
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
                    .foregroundStyle(Color.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var localSTTConfigFields: some View {
        VStack(spacing: 10) {
            ForEach(LocalSTTModel.allCases, id: \.self) { model in
                let isSelected = viewModel.localSTTModel == model

                Button {
                    viewModel.localSTTModel = model
                } label: {
                    HStack(spacing: 14) {
                        languageSelectionIndicator(isSelected: isSelected)
                            .scaleEffect(0.78)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.displayName)
                                .font(.studioBody(14, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                            Text(model.specs.summary)
                                .font(.studioBody(12))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(model.specs.sizeValue)
                            .font(.studioBody(11, weight: .semibold))
                            .foregroundStyle(isSelected ? StudioTheme.accent.opacity(0.92) : Color.white.opacity(0.44))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(isSelected ? 0.08 : 0.04)),
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
                    .foregroundStyle(Color.white.opacity(0.42))
                Text(L("onboarding.models.stt.local.hint"))
                    .font(.studioBody(12))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
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

        return onboardingConfigCard {
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

    private func onboardingConfigCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
                .foregroundStyle(Color.white.opacity(0.36))

            Text(viewModel.sttProvider.displayName)
                .font(.studioDisplay(18, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(sttProviderDescription(viewModel.sttProvider))
                .font(.studioBody(12))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if sttProviderNeedsConfiguration(viewModel.sttProvider) {
                    sttInlineConfig(for: viewModel.sttProvider)
                } else {
                    onboardingConfigCard {
                        Text("This provider is ready to use with the current defaults.")
                            .font(.studioBody(12))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
                .foregroundStyle(Color.white.opacity(0.36))

            Text(viewModel.llmProvider == .ollama ? L("provider.llm.ollama") : viewModel.llmRemoteProvider.displayName)
                .font(.studioDisplay(18, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(viewModel.llmProvider == .ollama
                ? L("settings.models.card.ollama.summary")
                : L("settings.models.card.\(viewModel.llmRemoteProvider.rawValue).summary"))
                .font(.studioBody(12))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if viewModel.llmProvider == .ollama {
                    ollamaConfigFields
                } else {
                    llmRemoteConfigFields
                }
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

    private func sttProviderToID(_ provider: STTProvider) -> StudioModelProviderID {
        switch provider {
        case .freeModel: .freeSTT
        case .whisperAPI: .whisperAPI
        case .localModel: .localSTT
        case .multimodalLLM: .multimodalLLM
        case .aliCloud: .aliCloud
        case .doubaoRealtime: .doubaoRealtime
        case .groq: .groqSTT
        case .appleSpeech: .appleSpeech
        }
    }

    private func loadProviderLogo(for providerID: StudioModelProviderID) -> NSImage? {
        guard let name = providerLogoResourceName(for: providerID) else { return nil }
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Resources/Providers",
        )
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Providers")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
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
        case .xiaomi: "circle.grid.cross"
        case .multimodalLLM: "brain.filled.head.profile"
        case .aliCloud: "antenna.radiowaves.left.and.right"
        case .doubaoRealtime: "bolt.horizontal.circle"
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
        case .groq: L("settings.models.card.groq.summary")
        case .appleSpeech: ""
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.08 : 0.05))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Group {
                            if let image = loadProviderLogo(for: providerID) {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .padding(6)
                            } else {
                                Image(systemName: providerSymbol(for: providerID))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(isSelected ? StudioTheme.accent : Color.white.opacity(0.62))
                            }
                        },
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.studioBody(14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text(description)
                        .font(.studioBody(11))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(2)
                }

                Spacer()

                Text(badge)
                    .font(.studioBody(9, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(isSelected ? StudioTheme.accent.opacity(0.95) : Color.white.opacity(0.42))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isSelected ? 0.08 : 0.04)),
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

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            editorialStepHeader(
                title: L("onboarding.permissions.title"),
                subtitle: L("onboarding.permissions.subtitle"),
                alignCenter: true,
            )

            VStack(spacing: 10) {
                ForEach(PrivacyGuard.PermissionID.allCases) { permissionID in
                    if let snapshot = viewModel.permissions.first(where: { $0.id == permissionID }) {
                        permissionCard(snapshot)
                    }
                }
            }

            privacyCallout
                .padding(.top, 8)
        }
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    private func permissionCard(_ snapshot: PrivacyGuard.PermissionSnapshot) -> some View {
        let isGranted = snapshot.isGranted
        let isRequesting = viewModel.requestingPermissions.contains(snapshot.id)

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isGranted ? 0.08 : 0.05))
                    .frame(width: 38, height: 38)
                Image(systemName: permissionIcon(snapshot.id))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isGranted ? StudioTheme.success : StudioTheme.accent.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.studioBody(13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(snapshot.detail)
                    .font(.studioBody(11))
                    .foregroundStyle(Color.white.opacity(0.5))
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
                Button {
                    viewModel.requestPermission(snapshot.id)
                } label: {
                    if isRequesting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.white.opacity(0.8))
                            .frame(width: 18, height: 18)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.88))
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(StudioInteractiveButtonStyle())
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.03)),
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1),
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private var privacyCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.74, green: 0.84, blue: 1.0))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy Centric")
                    .font(.studioBody(13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text("Your audio data is processed locally whenever possible. We never store recordings without your explicit consent.")
                    .font(.studioBody(12))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.9)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1),
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
        VStack(alignment: .leading, spacing: 16) {
            editorialStepHeader(
                title: "Keyboard Shortcuts",
                subtitle: "Default shortcuts are set, customize if needed.",
                alignCenter: false,
            )

            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    shortcutCard(
                        eyebrow: "Interaction",
                        title: L("settings.shortcuts.activation.title"),
                        icon: "mic.fill",
                        binding: HotkeyBinding.defaultActivation,
                        expanded: true,
                    )

                    shortcutCard(
                        eyebrow: "Universal",
                        title: L("settings.shortcuts.ask.title"),
                        icon: "sparkles",
                        binding: HotkeyBinding.defaultAsk,
                        expanded: false,
                    )
                    .frame(width: 264)
                }

                shortcutWideCard(
                    eyebrow: "Navigation",
                    title: L("settings.shortcuts.persona.title"),
                    icon: "person.crop.circle.fill",
                    binding: HotkeyBinding.defaultPersona,
                )

                keyboardHero
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func shortcutCard(
        eyebrow: String,
        title: String,
        icon: String,
        binding: HotkeyBinding,
        expanded: Bool,
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow)
                        .font(.studioBody(9, weight: .semibold))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.34))

                    Text(title)
                        .font(.studioDisplay(16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.93))
                }

                Spacer()

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.75, green: 0.82, blue: 1.0))
            }

            HStack(spacing: 8) {
                hotkeySequence(binding)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: expanded ? .infinity : nil, minHeight: 108, alignment: .topLeading)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private func shortcutWideCard(
        eyebrow: String,
        title: String,
        icon: String,
        binding: HotkeyBinding,
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.77, green: 0.84, blue: 1.0))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.studioBody(9, weight: .semibold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.34))
                Text(title)
                    .font(.studioDisplay(16, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.93))
            }

            Spacer()

            hotkeySequence(binding)
        }
        .padding(16)
        .background(onboardingCardFill)
        .overlay(onboardingCardStroke)
    }

    private var keyboardHero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.10, blue: 0.11),
                            Color(red: 0.06, green: 0.06, blue: 0.07),
                        ],
                        startPoint: .top,
                        endPoint: .bottom,
                    ),
                )

            keyboardPattern
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 90)
                .opacity(0.9)

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.92),
                ],
                startPoint: .center,
                endPoint: .bottom,
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Precision Workflow")
                    .font(.studioDisplay(18, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text("Designed for power users. Typeflux shortcuts integrate seamlessly with your existing operating system habits to keep your hands on the keys and your mind on the task.")
                    .font(.studioBody(13))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .frame(maxWidth: 430, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(height: 210)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1),
        )
    }

    private var keyboardPattern: some View {
        VStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<(row == 3 ? 12 : 14), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(index.isMultiple(of: 5) ? 0.10 : 0.07))
                            .frame(
                                width: row == 1 && index == 9 ? 70 : 42,
                                height: 32,
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.03), lineWidth: 1),
                            )
                    }
                }
            }
        }
        .blur(radius: 0.2)
    }

    @ViewBuilder
    private func hotkeySequence(_ binding: HotkeyBinding) -> some View {
        let keys = HotkeyFormat.components(binding)

        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
            if index > 0 {
                Text("+")
                    .font(.studioBody(12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))
            }

            hotkeyKeycap(key)
        }
    }

    private func hotkeyKeycap(_ key: String) -> some View {
        Text(key.uppercased())
            .font(.studioBody(12, weight: .bold))
            .tracking(key.count > 1 ? 0.8 : 0.2)
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, key.count > 2 ? 16 : 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1),
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

            if viewModel.isSkippable {
                footerTertiaryButton(title: L("onboarding.action.skip")) {
                    viewModel.skip()
                }
            }

            footerPrimaryButton(
                title: viewModel.isLastStep ? L("onboarding.action.getStarted") : L("onboarding.action.continue"),
            ) {
                viewModel.advance()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.55)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 8)
    }

    private func footerPrimaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.studioBody(10, weight: .bold))
                    .tracking(1.0)
                Image(systemName: viewModel.isLastStep ? "arrow.right" : "arrow.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Color.black.opacity(0.76))
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.67, green: 0.79, blue: 1.0), StudioTheme.accent],
                            startPoint: .leading,
                            endPoint: .trailing,
                        ),
                    ),
            )
            .shadow(color: StudioTheme.accent.opacity(0.32), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func footerSecondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.studioBody(10, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.44))
            .frame(height: 36)
            .padding(.horizontal, 12)
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func footerTertiaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.studioBody(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Color.white.opacity(0.22))
                .frame(height: 36)
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
                            .foregroundStyle(Color.white.opacity(0.94))
                            .lineLimit(2)

                        Text(subtitle)
                            .font(.studioBody(13))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    stepCounterPill
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
                            .foregroundStyle(Color.white.opacity(0.94))
                            .lineLimit(2)

                        Text(subtitle)
                            .font(.studioBody(13))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    HStack(spacing: 10) {
                        trailing
                        stepCounterPill
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignCenter ? .center : .leading)
    }

    private var stepCounterPill: some View {
        Text(stepCounterText)
            .font(.studioBody(10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.04)),
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1),
            )
    }

    private var onboardingCardFill: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.045))
    }

    private var onboardingCardStroke: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 1)
    }

    private func languageCardFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                isSelected
                    ? Color(red: 0.23, green: 0.23, blue: 0.25).opacity(0.96)
                    : Color.white.opacity(0.045),
            )
    }

    private func languageCardStroke(isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.05), lineWidth: 1)

            if isSelected {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(StudioTheme.accent.opacity(0.85), lineWidth: 1.2)
                    .padding(-2)
            }
        }
    }
}
