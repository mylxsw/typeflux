import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject private var localization = AppLocalization.shared
    @StateObject private var hotkeyRecorder = HotkeyRecorder()
    @State private var recordingTarget: OnboardingHotkeyTarget?

    private enum OnboardingHotkeyTarget {
        case activation, ask, persona
    }

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

            // Step dots
            stepIndicator
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(StudioTheme.surface.opacity(0.0))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(StudioTheme.border.opacity(0.3))
                .frame(height: 1)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
                if step == viewModel.currentStep {
                    Capsule()
                        .fill(StudioTheme.accent)
                        .frame(width: 20, height: 6)
                } else {
                    Circle()
                        .fill(step.rawValue < viewModel.currentStep.rawValue
                              ? StudioTheme.accent.opacity(0.45)
                              : StudioTheme.border.opacity(0.7))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: viewModel.currentStep)
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .language:
            languageStep
        case .models:
            modelsStep
        case .permissions:
            permissionsStep
        case .shortcuts:
            shortcutsStep
        }
    }

    // MARK: - Step 1: Language

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "globe",
                title: L("onboarding.language.title"),
                subtitle: L("onboarding.language.subtitle")
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
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? StudioTheme.accent.opacity(0.5) : StudioTheme.border.opacity(0.55),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    private func languageNativeName(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }

    private func languageEnglishName(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        }
    }

    // MARK: - Step 2: Models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "cpu",
                title: L("onboarding.models.title"),
                subtitle: L("onboarding.models.subtitle")
            )

            // STT Section
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(
                    icon: "waveform",
                    title: L("onboarding.models.stt.title"),
                    subtitle: L("onboarding.models.stt.subtitle")
                )

                VStack(spacing: 8) {
                    let sttProviders: [STTProvider] = [
                        .whisperAPI, .localModel, .multimodalLLM, .aliCloud, .doubaoRealtime
                    ]
                    ForEach(sttProviders, id: \.self) { provider in
                        modelProviderCard(
                            icon: sttProviderIcon(provider),
                            title: provider.displayName,
                            description: sttProviderDescription(provider),
                            badge: sttProviderBadge(provider),
                            isSelected: viewModel.sttProvider == provider
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.sttProvider = provider
                            }
                        }
                    }
                }

                // Contextual STT config
                if viewModel.sttProvider == .whisperAPI {
                    whisperConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.sttProvider == .localModel {
                    localSTTConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.sttProvider == .multimodalLLM {
                    multimodalLLMConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.sttProvider == .aliCloud {
                    aliCloudConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.sttProvider == .doubaoRealtime {
                    doubaoConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // LLM Section
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(
                    icon: "sparkles",
                    title: L("onboarding.models.llm.title"),
                    subtitle: L("onboarding.models.llm.subtitle")
                )

                VStack(spacing: 8) {
                    // Ollama (local)
                    modelProviderCard(
                        icon: "cpu",
                        title: L("provider.llm.ollama"),
                        description: L("settings.models.card.ollama.summary"),
                        badge: L("settings.models.badge.local"),
                        isSelected: viewModel.llmProvider == .ollama
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.selectOllama()
                        }
                    }

                    // Remote providers
                    ForEach(LLMRemoteProvider.allCases, id: \.self) { provider in
                        let isSelected = viewModel.llmProvider == .openAICompatible
                            && viewModel.llmRemoteProvider == provider
                        modelProviderCard(
                            icon: llmRemoteProviderIcon(provider),
                            title: provider.displayName,
                            description: L("settings.models.card.\(provider.rawValue).summary"),
                            badge: provider.apiStyle == .openAICompatible
                                ? L("settings.models.badge.api")
                                : L("settings.models.badge.native"),
                            isSelected: isSelected
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                viewModel.selectLLMRemoteProvider(provider)
                            }
                        }
                    }
                }

                // Contextual LLM config
                if viewModel.llmProvider == .openAICompatible {
                    openAICompatibleConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.llmProvider == .ollama {
                    ollamaConfigFields
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.sttProvider)
        .animation(.easeInOut(duration: 0.2), value: viewModel.llmProvider)
        .animation(.easeInOut(duration: 0.2), value: viewModel.llmRemoteProvider)
    }

    private func sttProviderIcon(_ provider: STTProvider) -> String {
        switch provider {
        case .whisperAPI: return "dot.radiowaves.left.and.right"
        case .localModel: return "laptopcomputer.and.arrow.down"
        case .multimodalLLM: return "brain.filled.head.profile"
        case .aliCloud: return "antenna.radiowaves.left.and.right"
        case .doubaoRealtime: return "bolt.horizontal.circle"
        case .appleSpeech: return "waveform"
        }
    }

    private func sttProviderBadge(_ provider: STTProvider) -> String {
        switch provider {
        case .localModel: return L("settings.models.badge.local")
        default: return L("settings.models.badge.api")
        }
    }

    private func sttProviderDescription(_ provider: STTProvider) -> String {
        switch provider {
        case .whisperAPI: return L("settings.models.card.whisper.summary")
        case .localModel: return L("settings.models.card.localSTT.summary")
        case .multimodalLLM: return L("settings.models.card.multimodal.summary")
        case .aliCloud: return L("settings.models.card.aliCloud.summary")
        case .doubaoRealtime: return L("settings.models.card.doubao.summary")
        case .appleSpeech: return ""
        }
    }

    private func llmRemoteProviderIcon(_ provider: LLMRemoteProvider) -> String {
        switch provider {
        case .custom: return "xmark.triangle.circle.square.fill"
        case .openRouter: return "arrow.triangle.branch"
        case .openAI: return "circle.hexagongrid"
        case .anthropic: return "sun.max"
        case .gemini: return "diamond"
        case .deepSeek: return "bird"
        case .kimi: return "moon.stars"
        case .qwen: return "cloud"
        case .zhipu: return "dot.scope"
        case .minimax: return "sparkles"
        }
    }

    private var whisperConfigFields: some View {
        StudioCard(padding: 16) {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("settings.models.whisper.endpoint"),
                    placeholder: "https://api.openai.com/v1",
                    text: $viewModel.whisperBaseURL
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.whisperAPIKey,
                    secure: true
                )
                StudioTextInputCard(
                    label: L("common.model"),
                    placeholder: "whisper-1",
                    text: $viewModel.whisperModel
                )
            }
        }
    }

    private var localSTTConfigFields: some View {
        StudioCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("settings.models.localSpeechModels"))
                    .font(.studioBody(11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)

                ForEach(LocalSTTModel.allCases, id: \.self) { model in
                    Button {
                        viewModel.localSTTModel = model
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(viewModel.localSTTModel == model ? StudioTheme.accent : StudioTheme.border.opacity(0.5))
                                .frame(width: 10, height: 10)
                            Text(model.displayName)
                                .font(.studioBody(13, weight: .medium))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Spacer()
                            Text(model.specs.sizeValue)
                                .font(.studioBody(11))
                                .foregroundStyle(StudioTheme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(L("onboarding.models.stt.local.hint"))
                    .font(.studioBody(11))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var multimodalLLMConfigFields: some View {
        StudioCard(padding: 16) {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("settings.models.remote.baseURL"),
                    placeholder: "https://api.openai.com/v1",
                    text: $viewModel.multimodalLLMBaseURL
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.multimodalLLMAPIKey,
                    secure: true
                )
                StudioTextInputCard(
                    label: L("common.model"),
                    placeholder: "gpt-4o",
                    text: $viewModel.multimodalLLMModel
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
                    secure: true
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
                    text: $viewModel.doubaoAppID
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

    private var openAICompatibleConfigFields: some View {
        StudioCard(padding: 16) {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("settings.models.remote.baseURL"),
                    placeholder: "https://api.openai.com/v1",
                    text: $viewModel.llmBaseURL
                )
                StudioTextInputCard(
                    label: L("common.apiKey"),
                    placeholder: "sk-...",
                    text: $viewModel.llmAPIKey,
                    secure: true
                )
                StudioTextInputCard(
                    label: L("common.model"),
                    placeholder: "gpt-4o-mini",
                    text: $viewModel.llmModel
                )
            }
        }
    }

    private var ollamaConfigFields: some View {
        StudioCard(padding: 16) {
            VStack(spacing: 12) {
                StudioTextInputCard(
                    label: L("settings.models.ollama.baseURL"),
                    placeholder: "http://127.0.0.1:11434",
                    text: $viewModel.ollamaBaseURL
                )
                StudioTextInputCard(
                    label: L("common.model"),
                    placeholder: "qwen2.5:7b",
                    text: $viewModel.ollamaModel
                )
            }
        }
    }

    private func modelProviderCard(
        icon: String,
        title: String,
        description: String,
        badge: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
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
                    fill: isSelected ? StudioTheme.accentSoft : StudioTheme.surfaceMuted
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
                    .fill(isSelected ? StudioTheme.accentSoft.opacity(0.6) : StudioTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? StudioTheme.accent.opacity(0.45) : StudioTheme.border.opacity(0.55),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(StudioInteractiveButtonStyle())
    }

    // MARK: - Step 3: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "lock.shield",
                title: L("onboarding.permissions.title"),
                subtitle: L("onboarding.permissions.subtitle")
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
                        .foregroundStyle(isGranted ? StudioTheme.success : StudioTheme.textSecondary)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(snapshot.title)
                        .font(.studioBody(14, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    StudioPill(
                        title: snapshot.badgeText,
                        tone: isGranted ? StudioTheme.success : StudioTheme.warning,
                        fill: isGranted ? StudioTheme.success.opacity(0.12) : StudioTheme.warning.opacity(0.1)
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
                    isLoading: isRequesting
                ) {
                    viewModel.requestPermission(snapshot.id)
                }
                .fixedSize()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isGranted ? StudioTheme.success.opacity(0.3) : StudioTheme.border.opacity(0.55),
                    lineWidth: 1
                )
        )
    }

    private func permissionIcon(_ id: PrivacyGuard.PermissionID) -> String {
        switch id {
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform"
        case .accessibility: return "hand.raised.fill"
        }
    }

    // MARK: - Step 4: Shortcuts

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(
                icon: "keyboard",
                title: L("onboarding.shortcuts.title"),
                subtitle: L("onboarding.shortcuts.subtitle")
            )

            VStack(spacing: 10) {
                shortcutRow(
                    icon: "mic.fill",
                    title: L("settings.shortcuts.activation.title"),
                    subtitle: L("onboarding.shortcuts.activation.hint"),
                    binding: HotkeyBinding.defaultActivation
                )
                shortcutRow(
                    icon: "text.quote",
                    title: L("settings.shortcuts.ask.title"),
                    subtitle: L("onboarding.shortcuts.ask.hint"),
                    binding: HotkeyBinding.defaultAsk
                )
                shortcutRow(
                    icon: "person.crop.circle",
                    title: L("settings.shortcuts.persona.title"),
                    subtitle: L("onboarding.shortcuts.persona.hint"),
                    binding: HotkeyBinding.defaultPersona
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
        binding: HotkeyBinding
    ) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StudioTheme.surfaceMuted)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
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

            Text(HotkeyFormat.display(binding))
                .font(.studioMono(13, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StudioTheme.surfaceMuted)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(StudioTheme.border.opacity(0.55), lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.55), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if viewModel.canGoBack {
                StudioButton(
                    title: L("onboarding.action.back"),
                    systemImage: "chevron.left",
                    variant: .secondary
                ) {
                    viewModel.goBack()
                }
            }

            Spacer()

            if viewModel.isSkippable {
                StudioButton(
                    title: L("onboarding.action.skip"),
                    systemImage: nil,
                    variant: .secondary
                ) {
                    viewModel.skip()
                }
            }

            StudioButton(
                title: viewModel.isLastStep ? L("onboarding.action.getStarted") : L("onboarding.action.continue"),
                systemImage: viewModel.isLastStep ? "checkmark" : "chevron.right",
                variant: .primary
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
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.accentSoft)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(StudioTheme.accent)
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

    private func sectionLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.studioBody(13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle)
                    .font(.studioBody(11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
        }
    }
}
