import SwiftUI

extension OnboardingView {
    var servicesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeading(L("setup.services.title"), L("setup.services.subtitle"))
            VStack(spacing: 0) {
                serviceOption(.cloud, icon: "cloud", title: "Typeflux Cloud",
                              detail: L("setup.services.cloud"), recommended: true)
                Rectangle().fill(setupPalette.separator).frame(height: 1).padding(.leading, 66)
                serviceOption(.custom, icon: "server.rack", title: L("setup.services.custom.title"),
                              detail: L("setup.services.custom"), recommended: false)
            }
            .background(setupPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(setupPalette.separator, lineWidth: 1))
            .padding(.top, 24)
            Button { viewModel.requestSetupSkip() } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("setup.services.launcherOnly"))
                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .medium))
                            .foregroundStyle(setupPalette.primary)
                        Text(launcherOnlyImpact)
                            .font(.studioBody(StudioTheme.Typography.bodySmall)).foregroundStyle(setupPalette.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(setupPalette.secondary)
                }
                .padding(.vertical, 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("setup.services.launcherOnly"))
            .accessibilityHint(launcherOnlyImpact)
            .overlay(alignment: .top) { Rectangle().fill(setupPalette.separator).frame(height: 1) }
            .padding(.top, 20)
            Spacer(minLength: 0)
        }
    }

    private var launcherOnlyImpact: String {
        if viewModel.speechConfigured, viewModel.languageConfigured { return L("setup.services.existingImpact") }
        if viewModel.speechConfigured { return L("setup.services.aiMissingImpact") }
        if viewModel.languageConfigured { return L("setup.services.speechMissingImpact") }
        return L("setup.services.launcherImpact")
    }

    private func serviceOption(_ route: OnboardingViewModel.ServiceRoute, icon: String,
                               title: String, detail: String, recommended: Bool) -> some View {
        let selected = viewModel.serviceRoute == route
        return Button { viewModel.chooseRoute(route) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? setupPalette.accent : setupPalette.secondary)
                    .frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(title).font(.studioBody(StudioTheme.Typography.cardTitle, weight: .semibold))
                            .foregroundStyle(setupPalette.primary)
                        if recommended {
                            Text(L("setup.services.recommended"))
                                .font(.studioBody(11, weight: .medium)).foregroundStyle(setupPalette.accent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(setupPalette.accent.opacity(0.12)))
                        }
                    }
                    Text(detail).font(.studioBody(StudioTheme.Typography.body)).foregroundStyle(setupPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? setupPalette.accent : setupPalette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(selected ? setupPalette.accent.opacity(0.055) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(recommended ? "\(L("setup.services.recommended")): \(detail)" : detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var cloudStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeading(L("setup.cloud.title"), L("setup.cloud.subtitle"))
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 18) {
                if !viewModel.authState.isLoggedIn {
                    HStack(spacing: 18) {
                        Image(nsImage: HelpAppIcon.image).resizable().interpolation(.high).frame(
                            width: 56,
                            height: 56
                        )
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(setupPalette.accent)
                        Image(systemName: "person.crop.circle").font(.system(size: 48, weight: .light))
                            .symbolRenderingMode(.palette).foregroundStyle(setupPalette.accent, setupPalette.muted)
                    }.accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("setup.cloud.speechService"), systemImage: "waveform")
                    Label(L("setup.finish.ai"), systemImage: "bubble.left.and.bubble.right")
                }
                .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .medium))
                .foregroundStyle(setupPalette.primary)
                Text(L("setup.cloud.entitlementNote"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall)).foregroundStyle(setupPalette.secondary)
                cloudConnectionStatus
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 12)
            Button {
                viewModel.chooseRoute(.custom)
                viewModel.currentStep = .stt
            } label: {
                HStack {
                    Text(L("setup.cloud.useOwn")).font(.studioBody(StudioTheme.Typography.body))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(setupPalette.accent)
                .padding(.vertical, 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("setup.cloud.useOwn"))
            .overlay(alignment: .top) { Rectangle().fill(setupPalette.separator).frame(height: 1) }
        }
    }

    @ViewBuilder private var cloudConnectionStatus: some View {
        if let error = viewModel.cloudError {
            Text(error).font(.studioBody(12.5)).foregroundStyle(StudioTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if viewModel.authState.isLoggedIn, viewModel.cloudCheckCompleted {
            Label(L("setup.cloud.aiReady"), systemImage: "checkmark.circle.fill")
                .font(.studioBody(12.5)).foregroundStyle(StudioTheme.success)
            if !viewModel.authState.canUseCloudASR {
                Text(L("setup.cloud.localNext")).font(.studioBody(12.5)).foregroundStyle(setupPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var speechSetupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                setupHeading(L("setup.speech.title"), L("setup.speech.subtitle"))
                if viewModel.serviceRoute == .cloud {
                    Text(L("setup.cloud.localNext")).font(.studioBody(13)).foregroundStyle(setupPalette.secondary)
                } else {
                    modelSubsteps(speech: true)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text(L("setup.speech.serviceLabel")).font(.studioBody(StudioTheme.Typography.body))
                        .foregroundStyle(setupPalette.secondary)
                    OnboardingSpeechServicePicker(
                        providers: ModelAvailability.configurationSpeechProviders
                            .filter { $0 != .typefluxOfficial || viewModel.authState.canUseCloudASR },

                        selection: Binding(get: { viewModel.settingsStore.sttProvider },
                                           set: viewModel.selectSpeechProvider), palette: setupPalette
                    )
                    Rectangle().fill(setupPalette.separator).frame(height: 1)
                    speechConnectionSummary
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(setupPalette.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(setupPalette.separator, lineWidth: 1))
                if let model = viewModel.configurationModel { setupTestFailure(model.sttConnectionTestState) }
                if viewModel.settingsStore.sttProvider == .localModel {
                    Text(L("setup.speech.hint")).font(.studioBody(12.5)).foregroundStyle(setupPalette.secondary)
                }
                HStack(spacing: 16) {
                    Image(systemName: "waveform").font(.system(size: 26, weight: .medium))
                        .foregroundStyle(setupPalette.accent)
                    Rectangle().fill(setupPalette.separator).frame(width: 1, height: 24)
                    Text(L("setup.speech.preview")).font(.studioBody(StudioTheme.Typography.bodyLarge))
                        .foregroundStyle(setupPalette.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 10).accessibilityHidden(true)
            }
            .padding(.bottom, 24)
        }.scrollIndicators(.hidden)
    }

    private var speechConnectionSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 17)).foregroundStyle(setupPalette.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L(viewModel.speechConfigured
                        ? (viewModel.settingsStore.sttProvider == .localModel
                            ? "setup.status.ready" : "setup.connection.configured")
                        : "setup.status.notSetUp"))
                    .font(.studioBody(StudioTheme.Typography.body)).foregroundStyle(setupPalette.primary)
                if viewModel.settingsStore.sttProvider == .localModel, !viewModel.speechConfigured,
                   viewModel.speechStatusText != L("setup.status.notSetUp") {
                    Text(viewModel.speechStatusText).font(.studioBody(12)).foregroundStyle(setupPalette.secondary)
                }
            }
            if viewModel.speechConfigured, !viewModel.speechVerified {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 6)).accessibilityHidden(true)
                    Text(L("setup.status.testNeeded")).font(.studioBody(12))
                }.foregroundStyle(StudioTheme.warning)
            }
            Spacer(minLength: 8)
            Button(L(viewModel.settingsStore.sttProvider == .localModel
                    ? "setup.speech.manage" : "setup.connection.edit")) {
                viewModel.editModels(.stt)
            }
            .font(.studioBody(StudioTheme.Typography.body)).buttonStyle(.link)
        }
    }

    private func modelSubsteps(speech: Bool) -> some View {
        HStack(spacing: 12) {
            modelSubstep("1", title: L("setup.cloud.speechService"), active: speech)
            Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(setupPalette.muted)
                .accessibilityHidden(true)
            modelSubstep("2", title: L("setup.language.shortTitle"), active: !speech)
        }
    }

    private func modelSubstep(_ number: String, title: String, active: Bool) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.studioBody(12, weight: .medium))
                .foregroundStyle(active ? Color.white : setupPalette.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(active ? setupPalette.accent : setupPalette.surface))
            Text(title).font(.studioBody(12.5, weight: active ? .medium : .regular))
                .foregroundStyle(active ? setupPalette.primary : setupPalette.secondary)
        }
    }

    var languageSetupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                setupHeading(L("setup.language.title"), L("setup.language.subtitle"))
                modelSubsteps(speech: false)
                VStack(alignment: .leading, spacing: 18) {
                    Text(L("common.model")).font(.studioBody(13)).foregroundStyle(setupPalette.secondary)
                    AskModelMenu(library: viewModel.modelLibrary,
                                 reference: Binding(get: { viewModel.modelLibrary.rewriteReference },
                                                    set: viewModel.selectLanguageModel),
                                 scenario: "rewrite", showsDefaultAction: false, fieldStyle: true,
                                 cloudAvailable: viewModel.authState.isLoggedIn,
                                 emptyTitle: L("setup.language.choose"), helpText: L("setup.language.hint"))
                    Rectangle().fill(setupPalette.separator).frame(height: 1)
                    HStack {
                        Text(viewModel.languageStatusText).font(.studioBody(13)).foregroundStyle(setupPalette.secondary)
                        Spacer()
                        Button(L("setup.language.configure")) { viewModel.editModels(.llm) }
                            .font(.studioBody(StudioTheme.Typography.body)).buttonStyle(.link)
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(setupPalette.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(setupPalette.separator, lineWidth: 1))
                setupTestFailure(viewModel.languageTestState)
            }
            .padding(.bottom, 24)
        }.scrollIndicators(.hidden)
    }

    @ViewBuilder private func setupTestFailure(_ state: ConnectionTestState) -> some View {
        switch state {
        case let .failure(message), let .notice(message):
            Text(message).font(.studioBody(13)).foregroundStyle(StudioTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
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
                Text(title).font(.studioBody(14, weight: .semibold)).foregroundStyle(setupPalette.primary)
                Text(detail).font(.studioBody(12.5)).foregroundStyle(setupPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ready, let action {
                Button(L("setup.action.configure"), action: action).buttonStyle(.link)
            }
        }.padding(.vertical, 20)
    }

    private func setupHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.studioDisplay(StudioTheme.Typography.heroTitle, weight: .semibold))
                .foregroundStyle(setupPalette.primary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.studioBody(StudioTheme.Typography.bodyLarge)).foregroundStyle(setupPalette.secondary)
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
