// swiftlint:disable file_length
import AppKit
import SwiftUI

struct OnboardingSpeechPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingSpeechModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingEditorialHeader(
                eyebrow: OnboardingStrings.text("eyebrow", table: "OnboardingSpeech"),
                title: OnboardingStrings.text("title", table: "OnboardingSpeech"),
                subtitle: OnboardingStrings.text("subtitle", table: "OnboardingSpeech"),
                pill: OnboardingStep.speech.pill
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
        .onAppear { model.refreshMicrophoneStatus() }
        .onDisappear { model.cancelTest() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.cancelRecordingIfActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMicrophoneStatus()
        }
    }

    private var providerList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.availableProviders, id: \.self) { provider in
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

    private var configPanel: some View {
        OnboardingConfigPanel(
            eyebrow: OnboardingStrings.text("configEyebrow", table: "OnboardingSpeech"),
            name: title(for: model.selectedProvider),
            provider: model.selectedProvider.studioProviderID,
            detail: detail(for: model.selectedProvider),
            fields: { VStack(alignment: .leading, spacing: 14) { configFields; configResult } },
            actions: { configActions },
            result: { EmptyView() }
        )
    }
}

private extension OnboardingSpeechPage {
    private var configFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.selectedProvider {
            case .localModel:
                localModelFields
            case .freeModel:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(OnboardingStrings.text("free.ready", table: "OnboardingSpeech"))
                        .font(.system(size: 12.5))
                }
                .padding(.vertical, 6)
            case .googleCloud:
                googleCloudFields
            case .multimodalLLM:
                Text(OnboardingStrings.text("multimodal.notice", table: "OnboardingSpeech"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            case .doubaoRealtime:
                doubaoFields
            case .whisperAPI:
                whisperFields
            default:
                apiKeyField(label: OnboardingStrings.text("field.apiKey", table: "OnboardingSpeech"))
            }
        }
    }

    private var localModelFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.text("field.model", table: "OnboardingSpeech"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                OnboardingModelPicker(
                    items: LocalSTTModel.displayOrder.map { local in
                        .init(id: local.rawValue, title: local.displayName,
                              detail: model.isModelAvailable(local)
                                  ? OnboardingStrings.text("local.downloadedTag", table: "OnboardingSpeech")
                                  : local.specs.sizeValue)
                    },
                    selection: model.selectedLocalModel.rawValue,
                    identifier: "onboarding.speech.model",
                    height: 36
                ) { id in
                    if let local = LocalSTTModel(rawValue: id) { model.selectLocalModel(local) }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.selectedLocalModel.displayName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        if model.selectedLocalModel == .senseVoiceSmall {
                            Text(OnboardingStrings.text("badge.recommended", table: "OnboardingSpeech"))
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        Text(model.selectedLocalModel.specs.sizeValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08), lineWidth: 1))
                }
            }

            HStack(spacing: 10) {
                if model.isLocalModelAvailable {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(OnboardingStrings.text("local.downloaded", table: "OnboardingSpeech"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if model.isDownloading {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text("\(Int(model.downloadProgress * 100))%")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(OnboardingStrings.text("local.cancel", table: "OnboardingSpeech")) {
                        model.cancelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Button {
                        model.startDownload()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text(OnboardingStrings.text("local.download", table: "OnboardingSpeech"))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(.primary.opacity(0.04), in: Capsule())
                        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 30)
        }
    }

    private var googleCloudFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if model.isGoogleAuthorized {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(OnboardingStrings.text("google.authorized", table: "OnboardingSpeech"))
                        .font(.system(size: 12.5))
                } else {
                    Button {
                        model.authorizeGoogleCloud()
                    } label: {
                        HStack(spacing: 6) {
                            Text(OnboardingStrings.text("google.authorizeAction", table: "OnboardingSpeech"))
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isAuthorizingGoogle)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(L("settings.models.googleCloud.projectID"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if model.isGoogleAuthorized,
                       model.googleProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(GoogleCloudSpeechError.missingProjectID.localizedDescription)
                            .font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                    }
                }
                TextField("my-project-id", text: $model.googleProjectID)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(.vertical, 6)
    }

    private var doubaoFields: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.text("field.appId", table: "OnboardingSpeech"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("App ID", text: $model.doubaoAppID)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
            }
            apiKeyField(label: OnboardingStrings.text("field.accessToken", table: "OnboardingSpeech"), token: true)
        }
    }

    private var whisperFields: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.text("field.endpoint", table: "OnboardingSpeech"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.openai.com/v1", text: $model.whisperBaseURL)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
            }
            apiKeyField(label: OnboardingStrings.text("field.apiKey", table: "OnboardingSpeech"))
        }
    }

    private func apiKeyField(label: String, token: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            SecureField(
                OnboardingStrings.text("placeholder.paste", table: "OnboardingSpeech", arguments: [label]),
                text: token ? $model.doubaoAccessToken : $model.apiKey
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                isTestFailure ? Color.red.opacity(0.6) : .primary.opacity(0.08),
                lineWidth: 1
            ))
        }
    }

    private var isTestFailure: Bool {
        if case .failure = model.testStatus {
            return true
        }
        return false
    }
}

private extension OnboardingSpeechPage {
    var configActions: some View {
        HStack(spacing: 12) {
            if let url = model.apiKeyHelpURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "key")
                            .font(.system(size: 11))
                        Text(OnboardingStrings.text(
                            "action.getKey",
                            table: "OnboardingSpeech",
                            arguments: [model.selectedProvider == .doubaoRealtime ? "Access Token" : "API Key"]
                        ))
                        .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            holdToTalkButton
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            TFDivider.form
        }
    }

    private var holdToTalkButton: some View {
        Button {
            // The drag gesture owns the press and release lifecycle.
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                Text(OnboardingStrings.text("action.testHoldToTalk", table: "OnboardingSpeech"))
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .foregroundStyle(model.canTest ? Color.white : Color.secondary)
            .background(model.canTest ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
            .opacity(model.canTest ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!model.canTest)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if model.testStatus != .recording, model.testStatus != .recognizing {
                        model.startHoldToTalk()
                    }
                }
                .onEnded { _ in
                    model.stopHoldToTalk()
                }
        )
    }

    @ViewBuilder
    private var configResult: some View {
        if model.isMicrophoneDenied {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(OnboardingStrings.text("error.micPermissionDenied", table: "OnboardingSpeech"))
                    .foregroundStyle(.primary)
                Spacer()
                Button(OnboardingStrings.text("action.openSettings", table: "OnboardingSpeech")) {
                    model.openSettings()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else {
            switch model.testStatus {
            case .recording:
                HStack(spacing: 10) {
                    WaveformView()
                    Text(OnboardingStrings.text("status.listening", table: "OnboardingSpeech"))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            case .recognizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(OnboardingStrings.text("status.recognizing", table: "OnboardingSpeech"))
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

    private func title(for provider: STTProvider) -> String {
        switch provider {
        case .localModel: OnboardingStrings.text("provider.local.title", table: "OnboardingSpeech")
        case .freeModel: OnboardingStrings.text("provider.free.title", table: "OnboardingSpeech")
        case .soniox: OnboardingStrings.text("provider.soniox.title", table: "OnboardingSpeech")
        case .aliCloud: OnboardingStrings.text("provider.ali.title", table: "OnboardingSpeech")
        case .doubaoRealtime: OnboardingStrings.text("provider.doubao.title", table: "OnboardingSpeech")
        case .googleCloud: OnboardingStrings.text("provider.google.title", table: "OnboardingSpeech")
        case .whisperAPI: OnboardingStrings.text("provider.whisper.title", table: "OnboardingSpeech")
        case .groq: OnboardingStrings.text("provider.groq.title", table: "OnboardingSpeech")
        case .multimodalLLM: OnboardingStrings.text("provider.multimodal.title", table: "OnboardingSpeech")
        default: provider.displayName
        }
    }

    private func detail(for provider: STTProvider) -> String {
        switch provider {
        case .localModel: OnboardingStrings.text("provider.local.detail", table: "OnboardingSpeech")
        case .freeModel: OnboardingStrings.text("provider.free.detail", table: "OnboardingSpeech")
        case .soniox: OnboardingStrings.text("provider.soniox.detail", table: "OnboardingSpeech")
        case .aliCloud: OnboardingStrings.text("provider.ali.detail", table: "OnboardingSpeech")
        case .doubaoRealtime: OnboardingStrings.text("provider.doubao.detail", table: "OnboardingSpeech")
        case .googleCloud: OnboardingStrings.text("provider.google.detail", table: "OnboardingSpeech")
        case .whisperAPI: OnboardingStrings.text("provider.whisper.detail", table: "OnboardingSpeech")
        case .groq: OnboardingStrings.text("provider.groq.detail", table: "OnboardingSpeech")
        case .multimodalLLM: OnboardingStrings.text("provider.multimodal.detail", table: "OnboardingSpeech")
        default: ""
        }
    }

    private func badge(for provider: STTProvider) -> String? {
        switch provider {
        case .localModel: OnboardingStrings.text("badge.recommended", table: "OnboardingSpeech")
        case .freeModel: OnboardingStrings.text("badge.free", table: "OnboardingSpeech")
        case .soniox, .aliCloud, .doubaoRealtime, .whisperAPI, .groq:
            OnboardingStrings.text("badge.apiKey", table: "OnboardingSpeech")
        case .googleCloud: OnboardingStrings.text("badge.auth", table: "OnboardingSpeech")
        case .multimodalLLM: OnboardingStrings.text("badge.advanced", table: "OnboardingSpeech")
        default: nil
        }
    }
}

private struct WaveformView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 5) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(
                        Animation.easeInOut(duration: 0.4)
                            .repeatForever()
                            .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .frame(height: 16)
        .onAppear { isAnimating = true }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if !isAnimating {
            return 4
        }
        let heights: [CGFloat] = [8, 16, 12, 14, 6]
        return heights[index % heights.count]
    }
}
