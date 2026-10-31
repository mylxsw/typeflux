import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let appearanceMode: AppearanceMode
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            VStack(spacing: 0) {
                page.padding(.top, 52).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                OnboardingFooterBar(back: back, tertiary: tertiary, primary: primary) {
                    if viewModel.currentStep == .welcome {
                        Menu {
                            ForEach(AppLanguage.allCases) { language in
                                Button(language.displayName) { viewModel.setLanguage(language) }
                            }
                        } label: {
                            Label(viewModel.appLanguage.displayName, systemImage: "globe")
                                .font(.system(size: 12))
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
        .alert(L("setup.skip.title"), isPresented: Binding(
            get: { viewModel.skipConfirmation != nil },
            set: {
                if !$0 {
                    viewModel.skipConfirmation = nil
                }
            }
        ), presenting: viewModel.skipConfirmation) { target in
            Button(L("setup.skip.confirm")) { viewModel.confirmSkip(target) }
            Button(L("setup.skip.back"), role: .cancel) { viewModel.skipConfirmation = nil }
        } message: { target in Text(viewModel.skipMessage(for: target)) }
        .onChange(of: viewModel.currentStep) { step in
            if step == .try {
                viewModel.voicePracticeBeganAt = Date()
                viewModel.voicePracticeSucceeded = false
            }
            viewModel.refreshSetup()
        }
        .onChange(of: viewModel.voicePracticeText) { _ in viewModel.updateVoicePractice() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.refreshGlobeKeyState()
        }
    }

    @ViewBuilder private var page: some View {
        switch viewModel.currentStep {
        case .welcome: OnboardingWelcomePage(viewModel: viewModel)
        case .route: OnboardingRoutePage(viewModel: viewModel, model: viewModel.routeModel)
        case .cloud: OnboardingCloudPage(viewModel: viewModel, model: viewModel.cloudModel)
        case .speech: OnboardingSpeechPage(viewModel: viewModel, model: viewModel.speechModel)
        case .llm: OnboardingLLMPage(viewModel: viewModel, model: viewModel.llmModel)
        case .permissions: OnboardingPermissionsPage(viewModel: viewModel, model: viewModel.permissionsModel)
        case .shortcuts: OnboardingShortcutsPage(viewModel: viewModel, model: viewModel.shortcutsModel)
        case .try: OnboardingTryPage(viewModel: viewModel, model: viewModel.tryModel)
        }
    }

    private var back: OnboardingFooterAction? {
        viewModel.canGoBack ? .init(title: OnboardingStrings.text("back"), perform: viewModel.goBack) : nil
    }

    private var primary: OnboardingFooterAction {
        let step = viewModel.currentStep
        return .init(title: OnboardingStrings.text(step == .welcome ? "start" : step == .try ? "finish" : "continue"),
                     enabled: !viewModel.isSetupActionRunning
                         && (viewModel.canAdvance || viewModel.pagePrimaryAction != nil)) {
            viewModel.performSetupAction()
        }
    }

    private var tertiary: OnboardingFooterAction? {
        switch viewModel.currentStep {
        case .route:
            nil // The route page places this link below its art cards.
        case .cloud:
            .init(title: OnboardingStrings.text("custom"), perform: viewModel.useCustomModels)
        case .speech:
            .init(title: OnboardingStrings.text("later")) { viewModel.requestSetupSkip() }
        case .llm:
            .init(title: OnboardingStrings.text("skip")) { viewModel.requestSetupSkip() }
        case .permissions:
            .init(title: OnboardingStrings.text("later"), perform: viewModel.skipPermissions)
        default: nil
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
