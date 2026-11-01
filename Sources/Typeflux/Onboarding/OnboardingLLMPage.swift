// swiftlint:disable file_length
import AppKit
import SwiftUI

struct OnboardingLLMPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingLLMModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingEditorialHeader(
                eyebrow: OnboardingStrings.text("eyebrow", table: "OnboardingLlm"),
                title: OnboardingStrings.text("title", table: "OnboardingLlm"),
                titleBadge: OnboardingStrings.text("titleBadge", table: "OnboardingLlm"),
                subtitle: OnboardingStrings.text("subtitle", table: "OnboardingLlm"),
                pill: OnboardingStep.llm.pill
            )

            HStack(alignment: .top, spacing: 18) {
                providerList
                    .frame(width: 330)

                configPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 34)
        .padding(.top, 6)
        .onAppear { model.activate() }
        .onDisappear { model.cancelPendingWork() }
    }

    private var providerList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.availablePrimaryProviders, id: \.self) { provider in
                    OnboardingProviderCard(
                        provider: provider.studioProviderID,
                        title: title(for: provider),
                        detail: detail(for: provider),
                        badge: badge(for: provider),
                        selected: model.selectedProvider == provider
                    ) {
                        model.selectProvider(provider)
                    }
                }

                if isSelectedInMoreProviders {
                    OnboardingProviderCard(
                        provider: model.selectedProvider.studioProviderID,
                        title: title(for: model.selectedProvider),
                        detail: detail(for: model.selectedProvider),
                        badge: badge(for: model.selectedProvider),
                        selected: true
                    ) {
                        // already selected
                    }
                }

                moreProvidersMenu
            }
            .padding(3)
        }
        .scrollIndicators(.hidden)
        .padding(-3)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: 0.88),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var isSelectedInMoreProviders: Bool {
        OnboardingLLMProvider.moreProviders.contains(model.selectedProvider)
    }

    private var moreProvidersMenu: some View {
        OnboardingModelPicker(
            items: OnboardingLLMProvider.moreProviders.map {
                .init(id: $0.id, title: title(for: $0), detail: detail(for: $0))
            },
            selection: model.selectedProvider.id, identifier: "onboarding.llm.moreProviders", height: 44
        ) { id in
            if let provider = OnboardingLLMProvider.moreProviders.first(where: { $0.id == id }) {
                model.selectProvider(provider)
            }
        } label: {
            HStack(spacing: 6) {
                Text(OnboardingStrings.text("provider.more", table: "OnboardingLlm"))
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.primary.opacity(0.12))
            )
        }
    }

    private var configPanel: some View {
        OnboardingConfigPanel(
            eyebrow: OnboardingStrings.text("configEyebrow", table: "OnboardingLlm"),
            name: title(for: model.selectedProvider),
            provider: model.selectedProvider.studioProviderID,
            fields: { VStack(alignment: .leading, spacing: 14) { configFields; configResult } },
            actions: { configActions },
            result: { EmptyView() }
        )
    }
}

private extension OnboardingLLMPage {
    private var configFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.selectedProvider {
            case .remote(.freeModel):
                freeModelField
            case .ollama:
                ollamaFields
            case .remote(.custom):
                customFields
            default:
                remoteAPIKeyFields
            }
        }
    }

    private var freeModelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OnboardingStrings.text("field.model", table: "OnboardingLlm"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            modelSelectorMenu(models: model.availableModels, enabled: true)
        }
    }

    private var ollamaFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isOllamaRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text(OnboardingStrings.text("field.model", table: "OnboardingLlm"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    modelSelectorMenu(models: model.availableModels, enabled: model.validationStatus == .valid)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(OnboardingStrings.text("error.ollamaNotFound", table: "OnboardingLlm"))
                        .font(.system(size: 12.5))
                    Spacer()
                    Button(OnboardingStrings.text("action.download", table: "OnboardingLlm")) {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)

                    Button(OnboardingStrings.text("action.retryDetect", table: "OnboardingLlm")) {
                        model.checkOllama()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.text("field.endpoint", table: "OnboardingLlm"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("https://…/v1", text: $model.customBaseURL)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
            }

            remoteAPIKeyFields
        }
    }

    private var remoteAPIKeyFields: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.text("field.apiKey", table: "OnboardingLlm"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    SecureField(
                        OnboardingStrings.text("placeholder.autoValidate", table: "OnboardingLlm"),
                        text: Binding(
                            get: { model.apiKey },
                            set: { model.onKeyChange($0) }
                        )
                    )
                    .textFieldStyle(.plain)

                    if model.validationStatus == .validating {
                        ProgressView()
                            .controlSize(.small)
                    } else if model.validationStatus == .valid {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        isInvalidKey ? Color.red.opacity(0.6) : .primary.opacity(0.08),
                        lineWidth: 1
                    )
                )
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.text("field.model", table: "OnboardingLlm"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                modelSelectorMenu(
                    models: model.availableModels,
                    enabled: model.validationStatus == .valid
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var isInvalidKey: Bool {
        if case .invalid = model.validationStatus {
            return true
        }
        return false
    }

    private func modelSelectorMenu(models: [String], enabled: Bool) -> some View {
        OnboardingModelPicker(
            items: models.enumerated().map { index, name in
                .init(id: name, title: name,
                      detail: index == 0 ? OnboardingStrings.text("badge.recommended", table: "OnboardingLlm") : nil)
            },
            selection: model.selectedModel,
            identifier: "onboarding.llm.model",
            enabled: enabled,
            onSelect: model.selectModel
        ) {
            HStack(spacing: 6) {
                Text(enabled ? (model.selectedModel.isEmpty ? (models.first ?? "") : model.selectedModel)
                    : OnboardingStrings.text("model.autoFetch", table: "OnboardingLlm"))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Spacer()
                if enabled, let first = models.first, model.selectedModel == first {
                    Text(OnboardingStrings.text("badge.recommended", table: "OnboardingLlm"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
        }
        .disabled(!enabled)
    }

    private var configActions: some View {
        HStack(spacing: 12) {
            if let url = model.apiKeyHelpURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "key")
                            .font(.system(size: 11))
                        Text(OnboardingStrings.text("action.getKey", table: "OnboardingLlm"))
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                model.testConnection()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 12))
                    Text(OnboardingStrings.text("action.testConnection", table: "OnboardingLlm"))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
                .foregroundStyle(model.validationStatus == .valid ? Color.primary : Color.secondary)
                .background(.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.validationStatus != .valid || model.isBusy)
            .opacity(model.validationStatus == .valid ? 1 : 0.4)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            TFDivider.form
        }
    }

    @ViewBuilder
    private var configResult: some View {
        if case let .invalid(message) = model.validationStatus {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer()
            }
            .padding(10)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else {
            switch model.testStatus {
            case .testing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(OnboardingStrings.text("status.testing", table: "OnboardingLlm"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            case let .success(preview, latencyMs):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("「\(preview)」")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(latencyMs) ms")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            case let .failure(message):
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            case .idle:
                EmptyView()
            }
        }
    }
}

private extension OnboardingLLMPage {
    static let providerKeys: [OnboardingLLMProvider: String] = [
        .remote(.freeModel): "free",
        .remote(.openAI): "openai",
        .remote(.anthropic): "anthropic",
        .remote(.gemini): "gemini",
        .remote(.deepSeek): "deepseek",
        .remote(.qwen): "qwen",
        .remote(.openRouter): "openrouter",
        .remote(.kimi): "kimi",
        .remote(.zhipu): "zhipu",
        .remote(.minimax): "minimax",
        .remote(.grok): "grok",
        .remote(.groq): "groq",
        .remote(.xiaomi): "xiaomi",
        .remote(.custom): "custom",
        .ollama: "ollama"
    ]

    func title(for provider: OnboardingLLMProvider) -> String {
        if let key = Self.providerKeys[provider] {
            return OnboardingStrings.text("provider.\(key).title", table: "OnboardingLlm")
        }
        if case let .remote(remote) = provider {
            return remote.displayName
        }
        return ""
    }

    func detail(for provider: OnboardingLLMProvider) -> String {
        guard let key = Self.providerKeys[provider] else { return "" }
        return OnboardingStrings.text("provider.\(key).detail", table: "OnboardingLlm")
    }

    private func badge(for provider: OnboardingLLMProvider) -> String? {
        switch provider {
        case .remote(.freeModel): OnboardingStrings.text("badge.free", table: "OnboardingLlm")
        case .ollama: OnboardingStrings.text("badge.local", table: "OnboardingLlm")
        case .remote(.custom): OnboardingStrings.text("badge.custom", table: "OnboardingLlm")
        default: OnboardingStrings.text("badge.apiKey", table: "OnboardingLlm")
        }
    }
}
