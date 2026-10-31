import SwiftUI

extension OnboardingView {
    var servicesStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            setupHeading(L("setup.services.title"), L("setup.services.subtitle"))
            HStack(spacing: 16) {
                serviceOption(.cloud, icon: "cloud", title: "Typeflux Cloud",
                              detail: L("setup.services.cloud"), recommended: true)
                serviceOption(.custom, icon: "slider.horizontal.3", title: L("setup.services.custom.title"),
                              detail: L("setup.services.custom"), recommended: false)
            }
            Button { viewModel.skipConfirmation = .allModels } label: {
                Text(L("setup.services.launcherOnly"))
                    .font(.studioBody(13)).foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 56).padding(.top, 18)
    }

    private func serviceOption(_ route: OnboardingViewModel.ServiceRoute, icon: String,
                               title: String, detail: String, recommended: Bool) -> some View {
        let selected = viewModel.serviceRoute == route
        return Button { viewModel.chooseRoute(route) } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: icon).font(.system(size: 28, weight: .light))
                        .foregroundStyle(StudioTheme.accent)
                    Spacer()
                    if recommended {
                        Text(L("setup.services.recommended"))
                            .font(.studioBody(11, weight: .medium)).foregroundStyle(StudioTheme.accent)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(StudioTheme.accent.opacity(0.1)))
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? StudioTheme.accent : StudioTheme.textTertiary)
                }
                Text(title).font(.studioBody(19, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Text(detail).font(.studioBody(13)).foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity).frame(height: 208, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(StudioTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(selected ? StudioTheme.accent : StudioTheme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(recommended ? "\(L("setup.services.recommended")): \(detail)" : detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var cloudStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            setupHeading(L("setup.cloud.title"), L("setup.cloud.subtitle"))
            if !viewModel.authState.isLoggedIn {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "person.crop.circle").font(.system(size: 32, weight: .light))
                        .foregroundStyle(StudioTheme.accent)
                    Text(L("setup.cloud.signInDetail")).font(.studioBody(14)).foregroundStyle(StudioTheme.textSecondary)
                    StudioButton(title: L("setup.cloud.signInShort"), systemImage: nil, variant: .primary) {
                        LoginWindowController.shared.show()
                    }
                }
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(StudioTheme.surface))
            } else if viewModel.isCheckingCloud {
                ProgressView(L("setup.cloud.checking")).frame(maxWidth: .infinity, minHeight: 180)
            } else if let error = viewModel.cloudError {
                Text(error).foregroundStyle(StudioTheme.warning)
                Button(L("setup.action.retry")) { Task { await viewModel.checkCloud() } }
            } else {
                VStack(spacing: 0) {
                    setupSummaryRow(title: L("setup.finish.ai"), detail: L("setup.cloud.aiReady"),
                                    ready: viewModel.cloudCheckCompleted, action: nil)
                    Divider()
                    setupSummaryRow(title: OnboardingFeature.voice.title,
                                    detail: viewModel.authState
                                        .canUseCloudASR ? L("setup.cloud.speechReady") : L("setup.cloud.localNext"),
                                    ready: viewModel.authState.canUseCloudASR, action: nil)
                }
                .padding(.horizontal, 20)
                .background(RoundedRectangle(cornerRadius: 16).fill(StudioTheme.surface))
            }
            Button(L("setup.cloud.useOwn")) {
                viewModel.chooseRoute(.custom); viewModel.currentStep = .stt
            }.buttonStyle(.link)
        }.padding(.horizontal, 56).padding(.top, 18)
    }

    var speechSetupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                setupHeading(L("setup.speech.title"), L("setup.speech.subtitle"))
                if viewModel.serviceRoute == .cloud {
                    Text(L("setup.cloud.localNext")).font(.studioBody(13)).foregroundStyle(StudioTheme.textSecondary)
                }
                TFFormSection {
                    TFFormRow(title: L("common.model"), icon: "waveform", controlWidth: .wide) {
                        TFPopUpButton(title: L("common.model"),
                                      options: ModelAvailability.configurationSpeechProviders
                                          .filter { $0 != .typefluxOfficial || viewModel.authState.canUseCloudASR }
                                          .map { TFOption($0, $0.displayName) },
                                      selection: Binding(get: { viewModel.settingsStore.sttProvider }, set: {
                                          viewModel.configurationModel?.setSTTProvider($0)
                                          viewModel.configurationModel?.sttConnectionTestState = .idle
                                          viewModel.settingsStore.sttProvider = $0
                                          viewModel.speechSkipped = false; viewModel.refreshSetup()
                                      }), width: 280)
                    }
                    TFDivider.formWithIcon
                    TFFormRow(title: L("setup.status.title"), icon: "checkmark.circle") {
                        Text(viewModel.speechStatusText).font(.studioBody(13))
                            .foregroundStyle(viewModel.speechConfigured ? StudioTheme.textPrimary : StudioTheme
                                .textSecondary)
                    }
                }
                HStack(spacing: 12) {
                    StudioButton(title: L("setup.speech.configure"), systemImage: nil, variant: .secondary) {
                        viewModel.editModels(.stt)
                    }
                    if viewModel.speechConfigured, !viewModel.speechVerified {
                        StudioButton(title: L("ask.models.test"), systemImage: nil, variant: .secondary) {
                            viewModel.configurationModel?.testSTTConnection()
                        }
                    }
                }
                if let model = viewModel.configurationModel {
                    OnboardingSpeechTestResult(model: model)
                }
                if viewModel.settingsStore.sttProvider == .localModel || !viewModel.speechVerified {
                    Text(L(viewModel.settingsStore
                            .sttProvider == .localModel ? "setup.speech.hint" : "setup.speech.remoteHint"))
                        .font(.studioBody(12)).foregroundStyle(StudioTheme.textTertiary)
                }
            }.padding(.horizontal, 56).padding(.top, 18)

        }.scrollIndicators(.hidden)
    }

    var languageSetupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                setupHeading(L("setup.language.title"), L("setup.language.subtitle"))
                TFFormSection {
                    TFFormRow(title: L("common.model"), icon: "sparkles", controlWidth: .wide) {
                        AskModelMenu(library: viewModel.modelLibrary,
                                     reference: Binding(
                                         get: { viewModel.modelLibrary.rewriteReference },
                                         set: viewModel.selectLanguageModel
                                     ),
                                     scenario: "rewrite", showsDefaultAction: false, fieldStyle: true,
                                     cloudAvailable: viewModel.authState.isLoggedIn,
                                     emptyTitle: L("setup.language.choose"), helpText: L("setup.language.hint"))
                    }
                }
                HStack(spacing: 12) {
                    StudioButton(title: L("setup.language.configure"), systemImage: nil, variant: .secondary) {
                        viewModel.editModels(.llm)
                    }
                    StudioButton(title: L("ask.models.test"), systemImage: nil, variant: .secondary,
                                 isDisabled: !viewModel.languageConfigured || viewModel.languageTestState == .testing,
                                 isLoading: viewModel.languageTestState == .testing) { viewModel.testLanguageModel() }
                }
                setupTestResult(viewModel.languageTestState)
                if !viewModel.languageVerified {
                    Text(L("setup.language.hint")).font(.studioBody(12)).foregroundStyle(StudioTheme.textTertiary)
                }
            }.padding(.horizontal, 56).padding(.top, 18)

        }.scrollIndicators(.hidden)
    }

    var modelEditorSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(viewModel.modelEditorDomain == .stt ? L("setup.speech.title") : L("setup.language.title"))
                    .font(.studioBody(20, weight: .semibold))
                Spacer()
                Button(L("setup.action.done")) {
                    viewModel.modelEditorDomain = nil; viewModel.refreshSetup()
                }.buttonStyle(ModelActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
            if let model = viewModel.configurationModel {
                StudioView(viewModel: model).onboardingModelEditor
            }
        }
        .padding(24).frame(width: 820, height: 550)
        .background(AskWindowBackdrop())
    }

    func setupSummaryRow(title: String, detail: String, ready: Bool, action: (() -> Void)?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 19)).foregroundStyle(ready ? StudioTheme.success : StudioTheme.textTertiary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.studioBody(14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Text(detail).font(.studioBody(12.5)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ready, let action {
                Button(L("setup.action.configure"), action: action).buttonStyle(.link)
            }
        }.padding(.vertical, 20)
    }

    private func setupHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.studioDisplay(28, weight: .bold)).foregroundStyle(StudioTheme.textPrimary)
            Text(subtitle).font(.studioBody(14)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder func setupTestResult(_ state: ConnectionTestState) -> some View {
        switch state {
        case .idle: EmptyView()
        case .testing: ProgressView(L("setup.status.testing"))
        case .success: Label(L("ask.models.testOK"), systemImage: "checkmark.circle.fill")
            .font(.studioBody(13)).foregroundStyle(StudioTheme.success)
        case let .failure(message), let .notice(message):
            Text(message).font(.studioBody(13)).foregroundStyle(StudioTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingSpeechTestResult: View {
    @ObservedObject var model: StudioViewModel
    var body: some View {
        Group {
            switch model.sttConnectionTestState {
            case .idle: EmptyView()
            case .testing: ProgressView(L("setup.status.testing"))
            case .success: Label(L("ask.models.testOK"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(StudioTheme.success)
            case let .failure(message), let .notice(message): Text(message).foregroundStyle(StudioTheme.warning)
            }
        }.font(.studioBody(13))
    }
}
