import AppKit
import SwiftUI

// swiftlint:disable file_length
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        ZStack {
            StudioTheme.windowBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar with branding and step indicator
                headerBar

                // Main scrollable content
                ScrollView {
                    VStack(spacing: 0) {
                        stepContent
                            .padding(.horizontal, 40)
                            .padding(.top, 32)
                            .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                }

                // Footer navigation
                footerBar
            }
        }
        .preferredColorScheme(nil)
        .environment(\.locale, localization.locale)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if viewModel.currentStep == .permissions {
                viewModel.refreshPermissions()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Brand
            HStack(spacing: 8) {
                Image(systemName: StudioTheme.Symbol.brand)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L("sidebar.appName"))
                    .font(.studioDisplay(14, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
            }

            Spacer()

            // Step dots + count
            stepIndicator
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(StudioTheme.surface.opacity(0.0)),
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(StudioTheme.border.opacity(0.3))
                .frame(height: 1)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(viewModel.visibleSteps.enumerated()), id: \.element.rawValue) { index, step in
                    if step == viewModel.currentStep {
                        Capsule()
                            .fill(StudioTheme.accent)
                            .frame(width: 20, height: 6)
                    } else {
                        Circle()
                            .fill(index < (viewModel.visibleSteps.firstIndex(of: viewModel.currentStep) ?? 0)
                                ? StudioTheme.accent.opacity(0.45)
                                : StudioTheme.border.opacity(0.7))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: viewModel.currentStep)

            if let currentIndex = viewModel.visibleSteps.firstIndex(of: viewModel.currentStep) {
                Text("\(currentIndex + 1) / \(viewModel.visibleSteps.count)")
                    .font(.studioBody(11))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Step Content

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

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12)

            // App icon
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(StudioTheme.accentSoft)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: StudioTheme.Symbol.brand)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(StudioTheme.accent),
                )
                .padding(.bottom, 20)

            // Title + tagline
            VStack(spacing: 8) {
                Text(L("sidebar.appName"))
                    .font(.studioDisplay(28, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L("onboarding.welcome.tagline"))
                    .font(.studioBody(15))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 36)

            // Feature highlights
            VStack(spacing: 10) {
                welcomeFeatureRow(
                    icon: "mic.fill",
                    color: StudioTheme.accent,
                    title: L("onboarding.welcome.feature1.title"),
                    desc: L("onboarding.welcome.feature1.desc"),
                )
                welcomeFeatureRow(
                    icon: "app.connected.to.app.below.fill",
                    color: Color(red: 0.45, green: 0.35, blue: 0.95),
                    title: L("onboarding.welcome.feature2.title"),
                    desc: L("onboarding.welcome.feature2.desc"),
                )
                welcomeFeatureRow(
                    icon: "sparkles",
                    color: Color(red: 0.95, green: 0.55, blue: 0.2),
                    title: L("onboarding.welcome.feature3.title"),
                    desc: L("onboarding.welcome.feature3.desc"),
                )
            }

            Spacer().frame(height: 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func welcomeFeatureRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(color),
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.studioBody(14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(desc)
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.45), lineWidth: 1),
        )
    }

    // MARK: - Step 1: Language

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "globe",
                title: L("onboarding.language.title"),
                subtitle: L("onboarding.language.subtitle"),
            )

            VStack(spacing: 10) {
                ForEach(AppLanguage.allCases) { language in
                    languageCard(language)
                }
            }
        }
    }

    private func languageCard(_ language: AppLanguage) -> some View {
        let isSelected = viewModel.appLanguage == language
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.setLanguage(language)
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(languageNativeName(language))
                        .font(.studioBody(15, weight: .semibold))
                        .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textPrimary)
                    Text(languageEnglishName(language))
                        .font(.studioBody(12))
                        .foregroundStyle(StudioTheme.textSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surface),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? StudioTheme.accent.opacity(0.5) : StudioTheme.border.opacity(0.55),
                        lineWidth: isSelected ? 1.5 : 1,
                    ),
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(StudioInteractiveButtonStyle())
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

    private func languageEnglishName(_ language: AppLanguage) -> String {
        switch language {
        case .english: "English"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        }
    }

    // MARK: - Step 2: STT (provider selection + inline config)

    private var sttStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "waveform",
                title: L("onboarding.models.stt.title"),
                subtitle: L("onboarding.sttProvider.subtitle"),
            )

            VStack(spacing: 8) {
                ForEach(STTProvider.settingsDisplayOrder, id: \.self) { provider in
                    VStack(spacing: 8) {
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

                        if viewModel.sttProvider == provider {
                            sttInlineConfig(for: provider)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity,
                                ))
                        }
                    }
                }
            }
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

    // MARK: - Step 3: LLM (provider selection + inline config)

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "sparkles",
                title: L("onboarding.models.llm.title"),
                subtitle: L("onboarding.llmProvider.subtitle"),
            )

            VStack(spacing: 8) {
                // Free model (first in list)
                ForEach(LLMRemoteProvider.settingsDisplayOrder.prefix(1), id: \.self) { provider in
                    let isSelected = viewModel.llmProvider == .openAICompatible
                        && viewModel.llmRemoteProvider == provider
                    VStack(spacing: 8) {
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
                        if isSelected {
                            llmRemoteConfigFields
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity,
                                ))
                        }
                    }
                }

                // Ollama
                VStack(spacing: 8) {
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
                    if viewModel.llmProvider == .ollama {
                        ollamaConfigFields
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity,
                            ))
                    }
                }

                // Other remote providers
                ForEach(LLMRemoteProvider.settingsDisplayOrder.dropFirst(), id: \.self) { provider in
                    let isSelected = viewModel.llmProvider == .openAICompatible
                        && viewModel.llmRemoteProvider == provider
                    VStack(spacing: 8) {
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
                        if isSelected {
                            llmRemoteConfigFields
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity,
                                ))
                        }
                    }
                }
            }
        }
    }

    private func sttProviderIcon(_ provider: STTProvider) -> String {
        switch provider {
        case .freeModel: "giftcard"
        case .whisperAPI: "dot.radiowaves.left.and.right"
        case .localModel: "laptopcomputer.and.arrow.down"
        case .multimodalLLM: "brain.filled.head.profile"
        case .aliCloud: "antenna.radiowaves.left.and.right"
        case .doubaoRealtime: "bolt.horizontal.circle"
        case .groq: "bolt.fill"
        case .appleSpeech: "waveform"
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

    private func llmRemoteProviderIcon(_ provider: LLMRemoteProvider) -> String {
        switch provider {
        case .freeModel: "giftcard"
        case .custom: "xmark.triangle.circle.square.fill"
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
        case .xiaomi: "circle.grid.cross"
        }
    }

    private var whisperConfigFields: some View {
        StudioCard(padding: 16) {
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
        StudioCard(padding: 16) {
            VStack(spacing: 12) {
                if FreeSTTModelRegistry.suggestedModelNames.isEmpty {
                    Text(L("settings.models.freeSTT.noSources"))
                        .font(.studioBody(12))
                        .foregroundStyle(StudioTheme.textTertiary)
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
                    .foregroundStyle(StudioTheme.textTertiary)
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
                        // Radio indicator
                        ZStack {
                            Circle()
                                .stroke(
                                    isSelected ? StudioTheme.accent : StudioTheme.border.opacity(0.55),
                                    lineWidth: 1.5,
                                )
                                .frame(width: 20, height: 20)
                            if isSelected {
                                Circle()
                                    .fill(StudioTheme.accent)
                                    .frame(width: 10, height: 10)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayName)
                                .font(.studioBody(14, weight: .semibold))
                                .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textPrimary)
                            Text(model.specs.summary)
                                .font(.studioBody(12))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(model.specs.sizeValue)
                            .font(.studioBody(11, weight: .medium))
                            .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted),
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? StudioTheme.accentSoft.opacity(0.6) : StudioTheme.surface),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isSelected ? StudioTheme.accent.opacity(0.45) : StudioTheme.border.opacity(0.55),
                                lineWidth: isSelected ? 1.5 : 1,
                            ),
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(StudioInteractiveButtonStyle())
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                Text(L("onboarding.models.stt.local.hint"))
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    private var multimodalLLMConfigFields: some View {
        StudioCard(padding: 16) {
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
        StudioCard(padding: 16) {
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
        StudioCard(padding: 16) {
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
        StudioCard(padding: 16) {
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

        return StudioCard(padding: 16) {
            VStack(spacing: 12) {
                if provider == .freeModel {
                    if FreeLLMModelRegistry.suggestedModelNames.isEmpty {
                        Text(L("settings.models.freeModel.noSources"))
                            .font(.studioBody(12))
                            .foregroundStyle(StudioTheme.textTertiary)
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
                        .foregroundStyle(StudioTheme.textTertiary)
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
        StudioCard(padding: 16) {
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

    // MARK: - Provider Logo Helpers

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
            forResource: name, withExtension: "png", subdirectory: "Resources/Providers",
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

    // MARK: - Provider Card

    private func modelProviderCard(
        providerID: StudioModelProviderID,
        title: String,
        description: String,
        badge: String,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Group {
                            if let image = loadProviderLogo(for: providerID) {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .padding(7)
                            } else {
                                Image(systemName: providerSymbol(for: providerID))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
                            }
                        },
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.studioBody(14, weight: .semibold))
                        .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textPrimary)
                    Text(description)
                        .font(.studioBody(12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                StudioPill(
                    title: badge,
                    tone: isSelected ? StudioTheme.accent : StudioTheme.textTertiary,
                    fill: isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted,
                )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? StudioTheme.accentSoft.opacity(0.6) : StudioTheme.surface),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? StudioTheme.accent.opacity(0.45) : StudioTheme.border.opacity(0.55),
                        lineWidth: isSelected ? 1.5 : 1,
                    ),
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    // MARK: - Permissions Step

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "lock.shield",
                title: L("onboarding.permissions.title"),
                subtitle: L("onboarding.permissions.subtitle"),
            )

            VStack(spacing: 10) {
                ForEach(PrivacyGuard.PermissionID.allCases) { permissionID in
                    if let snapshot = viewModel.permissions.first(where: { $0.id == permissionID }) {
                        permissionCard(snapshot)
                    }
                }
            }
        }
    }

    private func permissionCard(_ snapshot: PrivacyGuard.PermissionSnapshot) -> some View {
        let isGranted = snapshot.isGranted
        let isRequesting = viewModel.requestingPermissions.contains(snapshot.id)

        return HStack(alignment: .top, spacing: 14) {
            // Icon
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isGranted ? StudioTheme.success.opacity(0.12) : StudioTheme.surfaceMuted)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: permissionIcon(snapshot.id))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isGranted ? StudioTheme.success : StudioTheme.textSecondary),
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(snapshot.title)
                        .font(.studioBody(14, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    StudioPill(
                        title: snapshot.badgeText,
                        tone: isGranted ? StudioTheme.success : StudioTheme.warning,
                        fill: isGranted ? StudioTheme.success.opacity(0.12) : StudioTheme.warning.opacity(0.1),
                    )
                }

                Text(snapshot.detail)
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !isGranted {
                StudioButton(
                    title: snapshot.actionTitle,
                    systemImage: nil,
                    variant: .primary,
                    isLoading: isRequesting,
                ) {
                    viewModel.requestPermission(snapshot.id)
                }
                .fixedSize()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isGranted ? StudioTheme.success.opacity(0.3) : StudioTheme.border.opacity(0.55),
                    lineWidth: 1,
                ),
        )
    }

    private func permissionIcon(_ id: PrivacyGuard.PermissionID) -> String {
        switch id {
        case .microphone: "mic.fill"
        case .speechRecognition: "waveform"
        case .accessibility: "hand.raised.fill"
        }
    }

    // MARK: - Shortcuts Step

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "keyboard",
                title: L("onboarding.shortcuts.title"),
                subtitle: L("onboarding.shortcuts.subtitle"),
            )

            VStack(spacing: 10) {
                shortcutRow(
                    icon: "mic.fill",
                    title: L("settings.shortcuts.activation.title"),
                    subtitle: L("onboarding.shortcuts.activation.hint"),
                    binding: HotkeyBinding.defaultActivation,
                )
                shortcutRow(
                    icon: "text.quote",
                    title: L("settings.shortcuts.ask.title"),
                    subtitle: L("onboarding.shortcuts.ask.hint"),
                    binding: HotkeyBinding.defaultAsk,
                )
                shortcutRow(
                    icon: "person.crop.circle",
                    title: L("settings.shortcuts.persona.title"),
                    subtitle: L("onboarding.shortcuts.persona.hint"),
                    binding: HotkeyBinding.defaultPersona,
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                Text(L("onboarding.shortcuts.changeInSettings"))
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
        }
    }

    private func shortcutRow(
        icon: String,
        title: String,
        subtitle: String,
        binding: HotkeyBinding,
    ) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StudioTheme.surfaceMuted)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary),
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.studioBody(14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(HotkeyFormat.components(binding), id: \.self) { key in
                    Text(key)
                        .font(.studioBody(13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(StudioTheme.surface),
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(StudioTheme.border.opacity(0.75), lineWidth: 1),
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.55), lineWidth: 1),
        )
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if viewModel.canGoBack {
                StudioButton(
                    title: L("onboarding.action.back"),
                    systemImage: "chevron.left",
                    variant: .secondary,
                ) {
                    viewModel.goBack()
                }
            }

            Spacer()

            if viewModel.isSkippable {
                StudioButton(
                    title: L("onboarding.action.skip"),
                    systemImage: nil,
                    variant: .secondary,
                ) {
                    viewModel.skip()
                }
            }

            StudioButton(
                title: viewModel.isLastStep ? L("onboarding.action.getStarted") : L("onboarding.action.continue"),
                systemImage: viewModel.isLastStep ? "checkmark" : "chevron.right",
                variant: .primary,
            ) {
                viewModel.advance()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudioTheme.border.opacity(0.3))
                .frame(height: 1)
        }
    }

    // MARK: - Shared Components

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        stepHeader(providerID: nil, icon: icon, title: title, subtitle: subtitle)
    }

    private func stepHeader(
        providerID: StudioModelProviderID?,
        icon: String,
        title: String,
        subtitle: String,
    ) -> some View {
        let logoImage = providerID.flatMap { loadProviderLogo(for: $0) }
        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(logoImage != nil ? Color.white.opacity(0.95) : StudioTheme.accentSoft)
                .frame(width: 48, height: 48)
                .overlay(
                    Group {
                        if let logo = logoImage {
                            Image(nsImage: logo)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .padding(8)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(StudioTheme.accent)
                        }
                    },
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.studioDisplay(20, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
