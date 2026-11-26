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
                OnboardingFooterBar(back: back, tertiary: tertiary, primary: primary,
                                    hint: footerHint) {
                    if viewModel.currentStep == .welcome {
                        OnboardingModelPicker(
                            items: AppLanguage.allCases.map { .init(id: $0.rawValue, title: $0.displayName) },
                            selection: viewModel.appLanguage.rawValue, identifier: "onboarding.language", height: 26,
                            onSelect: { id in
                                if let language = AppLanguage(rawValue: id) { viewModel.setLanguage(language) }
                            }
                        ) {
                            Label(viewModel.appLanguage.displayName, systemImage: "globe")
                                .font(.system(size: 12))
                        }
                        .frame(width: 120)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, localization.locale)
        .alert(skipTitle, isPresented: Binding(
            get: { viewModel.skipConfirmation != nil },
            set: {
                if !$0 {
                    viewModel.skipConfirmation = nil
                }
            }
        ), presenting: viewModel.skipConfirmation) { target in
            Button(target == .fileSearch ? OnboardingFileSearchPage.text("skip.confirm") : L("setup.skip.confirm")) {
                viewModel.confirmSkip(target)
            }
            let backTitle = target == .fileSearch ? OnboardingFileSearchPage.text("skip.back") : L("setup.skip.back")
            Button(backTitle, role: .cancel) {
                viewModel.skipConfirmation = nil
            }
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
        case .fileSearch: OnboardingFileSearchPage(viewModel: viewModel)
        case .shortcuts: OnboardingShortcutsPage(viewModel: viewModel, model: viewModel.shortcutsModel)
        case .try: OnboardingTryPage(viewModel: viewModel, model: viewModel.tryModel)
        case .recall: OnboardingRecallPage(viewModel: viewModel)
        }
    }

    private var skipTitle: String {
        viewModel.skipConfirmation == .fileSearch ? OnboardingFileSearchPage.text("skip.title") : L("setup.skip.title")
    }

    private var footerHint: String? {
        switch viewModel.currentStep {
        case .permissions: viewModel.permissionsModel.footerHint
        case .shortcuts: shortcutsHint
        default: nil
        }
    }

    private var shortcutsHint: String? {
        guard viewModel.currentStep == .shortcuts, viewModel.shortcutsModel.conflictCount > 0 else { return nil }
        return OnboardingShortcutsModel.text("conflictCount", arguments: [viewModel.shortcutsModel.conflictCount])
    }

    private var back: OnboardingFooterAction? {
        viewModel.canGoBack ? .init(title: OnboardingStrings.text("back"), perform: viewModel.goBack) : nil
    }

    private var primary: OnboardingFooterAction {
        let step = viewModel.currentStep
        let title = switch step {
        case .welcome: OnboardingStrings.text("start")
        case .recall: OnboardingStrings.text("finish")
        case .fileSearch where viewModel.fileSearchChoice != .off: OnboardingFileSearchPage.text("enable")
        default: OnboardingStrings.text("continue")
        }
        return .init(title: title,
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
        case .shortcuts:
            .init(title: OnboardingShortcutsModel.text("useDefaults"), perform: viewModel.shortcutsModel.useDefaults)
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
