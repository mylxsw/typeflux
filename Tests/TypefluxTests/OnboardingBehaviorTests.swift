import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingBehaviorTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func fixture(_ check: (SettingsStore, OnboardingViewModel, NSView) async throws -> Void,
                         language: AppLanguage = .english, appearance: AppearanceMode = .light) async throws {
        try await UI.withFixture { settings in
            settings.appLanguage = language
            AppLocalization.shared.setLanguage(language)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let manager = OnboardingTestModelManager()
            let model = OnboardingViewModel(settingsStore: settings, modelLibrary: library,
                                            globeKeyReader: OnboardingReadyGlobeKey(), localModelManager: manager,
                                            onComplete: {})
            model.configurationModel = StudioViewModel(settingsStore: settings,
                                                       historyStore: OnboardingTestHistoryStore(),
                                                       initialSection: .models,
                                                       localModelManager: manager, modelLibrary: library)
            try await UI.withWindow(OnboardingView(viewModel: model, appearanceMode: appearance),
                                    width: OnboardingWindowController.windowWidth,
                                    height: OnboardingWindowController.windowHeight) { _, host in
                try await check(settings, model, host)
            }
        }
    }

    private func capture(_ host: NSView, name: String) async throws {
        // Accessibility updates before a page transition finishes drawing.
        try await Task.sleep(for: .milliseconds(300))
        try UI.snapshot(host, name: name)
    }

    @Test func `welcome opens service choice before permissions`() async throws {
        try await fixture { _, model, host in
            try await capture(host, name: "01-welcome-en")
            try UI.button(L("onboarding.v2.action.start"), in: host).press()
            try await UI.wait { model.currentStep == .services }
            try await UI.wait { UI.contains(L("setup.services.title"), in: host) }
            let cloud = try UI.button("Typeflux Cloud", in: host)
            let hint = cloud.value("accessibilityHelp") as? String ?? ""
            #expect(hint.contains(L("setup.services.recommended")))
            #expect(model.serviceRoute == .cloud)
            try await capture(host, name: "02-services-en")
            try UI.button(L("onboarding.v2.action.continue"), in: host).press()
            try await UI.wait { model.currentStep == .cloud }
            try await UI.wait { UI.contains(L("setup.cloud.signInShort"), in: host) }
            #expect(!model.canAdvance)
            try await capture(host, name: "03-cloud-en")
        }
    }

    @Test func `custom route shows speech then language and can skip separately`() async throws {
        try await fixture { settings, model, host in
            model.currentStep = .services
            try await UI.wait { UI.contains(L("setup.services.custom.title"), in: host) }
            try UI.button(L("setup.services.custom.title"), in: host).press()
            try UI.button(L("onboarding.v2.action.continue"), in: host).press()
            try await UI.wait { model.currentStep == .stt }
            try await UI.wait { UI.contains(L("setup.speech.title"), in: host) }
            #expect(!model.canAdvance)
            try await capture(host, name: "04-speech-en")
            try UI.button(L("setup.action.skip"), in: host).press()
            #expect(model.skipConfirmation == .speech)
            #expect(!settings.onboardingSpeechDeferred)
            model.confirmSkip()
            try await UI.wait { model.currentStep == .llm }
            try await UI.wait { UI.contains(L("setup.language.title"), in: host) }
            #expect(UI.contains(L("setup.language.choose"), in: host))
            try await capture(host, name: "05-language-en")
            model.skipConfirmation = .language; model.confirmSkip()
            try await UI.wait { model.currentStep == .permissions }
            #expect(model.requiredPermissionIDs == [.accessibility])
        }
    }

    @Test func `launcher only finish shows missing capabilities and recovery`() async throws {
        try await fixture { settings, model, host in
            model.currentStep = .services
            try await UI.wait { UI.contains(L("setup.services.launcherOnly"), in: host) }
            try UI.button(L("setup.services.launcherOnly"), in: host).press()
            #expect(model.skipConfirmation == .allModels)
            model.confirmSkip()
            model.currentStep = .finish
            try await UI.wait { UI.contains(L("setup.finish.speechSkipped"), in: host) }
            #expect(UI.contains(L("setup.status.notSetUp"), in: host))
            #expect(!UI.contains(L("onboarding.v2.finish.title"), in: host))
            try await capture(host, name: "08-finish-skipped-en")
            let fixes = UI.elements(in: host)
                .filter {
                    [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.link.rawValue].contains($0.role)
                        && $0.label == L("setup.action.configure")
                }
            #expect(fixes.count == 2)
            try #require(fixes.first).press()
            try await UI.wait { model.currentStep == .stt }
            #expect(model.serviceRoute == .custom)
            #expect(!settings.isOnboardingCompleted)
        }
    }

    @Test func `launcher only explains accessibility without asking for voice access`() async throws {
        try await fixture { _, model, host in
            model.serviceRoute = .launcherOnly
            model.speechSkipped = true; model.aiSkipped = true
            model.currentStep = .permissions
            try await UI.wait { UI.contains(L("setup.permission.launcherAccessibility"), in: host) }
            #expect(model.requiredPermissionIDs == [.accessibility])
            let voiceVisible = UI.contains(OnboardingFeature.voice.title, in: host)
            #expect(!voiceVisible)
            try await capture(host, name: "06-launcher-permissions-en")
        }
    }

    @Test func `practice does not celebrate typed text`() async throws {
        try await fixture { _, model, host in
            model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(
                id: $0,
                state: .granted,
                detail: "Granted"
            ) }
            model.currentStep = .voice
            try await UI.wait { UI.contains(
                L("onboarding.v2.voice.practice.placeholder", HotkeyFormat.display(.defaultActivation)),
                in: host
            ) }
            model.voicePracticeText = "Typed text"
            #expect(!model.didPracticeVoice)
            #expect(!UI.contains(L("onboarding.v2.voice.practice.done"), in: host))
        }
    }

    @Test func `chinese pages render without clipped controls`() async throws {
        try await fixture({ _, model, host in
            for (step, name, title) in [
                (OnboardingViewModel.Step.services, "02-services-zh", "setup.services.title"),
                (.cloud, "03-cloud-zh", "setup.cloud.title"),
                (.stt, "04-speech-zh", "setup.speech.title"),
                (.llm, "05-language-zh", "setup.language.title"),
                (.permissions, "06-permissions-zh", "onboarding.v2.permissions.subtitle"),
                (.finish, "08-finish-zh", "setup.finish.title")
            ] {
                model.currentStep = step
                try await UI.wait { UI.contains(L(title), in: host) }
                try await capture(host, name: name)
                let button = try UI.button(
                    L(step == .finish ? "onboarding.v2.action.finish" : "onboarding.v2.action.continue"),
                    in: host
                )
                #expect(host.window?.frame.contains(button.frame) == true)
            }
        }, language: .simplifiedChinese, appearance: .dark)
    }

    @Test func `all permission rows and keyboard fix remain inside the viewport`() async throws {
        try await fixture { settings, model, host in
            (model.localModelManager as? OnboardingTestModelManager)?.available = true
            settings.useAppleSpeechFallback = true
            model.isGlobeKeyReady = false
            model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(
                id: $0,
                state: .needsAttention,
                detail: "Missing"
            ) }
            model.currentStep = .permissions
            try await UI.wait { UI.contains(L("onboarding.v2.globe.title"), in: host) }
            #expect(model.requiredPermissionIDs.count == 3)
            #expect(!model.canAdvance)
            let next = try UI.button(L("onboarding.v2.action.continue"), in: host)
            #expect(host.window?.frame.contains(next.frame) == true)
            try await capture(host, name: "06-permissions-with-keyboard-fix")
        }
    }

    @Test func `configured finish shows ready summary`() async throws {
        try await fixture { settings, model, host in
            settings.sttProvider = .whisperAPI
            settings.whisperAPIKey = "fixture-key"
            settings.whisperBaseURL = "https://example.com/v1"
            settings.whisperModel = "fixture-model"
            model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(
                id: $0,
                state: .granted,
                detail: "Granted"
            ) }
            try model.modelLibrary.save(
                .init(id: "sample", name: "My model", baseURL: "http://localhost:1234/v1", model: "sample"),
                key: ""
            )
            try model.selectLanguageModel(#require(model.modelLibrary.firstLocalReference(hasImage: false)))
            model.currentStep = .finish
            try await UI.wait { UI.contains(L("setup.finish.readySubtitle"), in: host) }
            #expect(!UI.contains(L("setup.status.testNeeded"), in: host))
            try await capture(host, name: "08-finish-ready-en")
        }
    }

    @Test func `native controller keeps window size across animated pages`() async throws {
        try await UI.withFixture { settings in
            let controller = OnboardingWindowController()
            controller.show(settingsStore: settings, onComplete: {})
            let window = try #require(controller.window)
            let model = try #require(controller.viewModel)
            let original = window.frame.size
            defer { window.close() }
            model.advance()
            model.chooseRoute(.custom); model.advance()
            model.skipConfirmation = .speech; model.confirmSkip()
            model.skipConfirmation = .language; model.confirmSkip()
            model.skipPermissions(); model.confirmSkip()
            try await UI.wait { model.currentStep == .launcher }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.frame.size == original)
            #expect(window.contentView?.bounds.width == OnboardingWindowController.windowWidth)
            #expect(original.height <= OnboardingWindowController.windowHeight + 32)
        }
    }

    @Test func `native footer keeps comfortable bottom spacing on every stage`() async throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            try await UI.withFixture { settings in
                settings.appLanguage = language
                settings.appearanceMode = language == .english ? .light : .dark
                AppLocalization.shared.setLanguage(language)
                let controller = OnboardingWindowController()
                controller.show(settingsStore: settings, onComplete: {})
                let window = try #require(controller.window)
                let host = try #require(window.contentView)
                let model = try #require(controller.viewModel)
                defer { window.close() }
                var firstBottom: CGFloat?
                for (step, key) in [
                    (OnboardingViewModel.Step.welcome, "onboarding.v2.action.start"),
                    (.services, "onboarding.v2.action.continue"),
                    (.permissions, "onboarding.v2.action.continue"),
                    (.finish, "onboarding.v2.action.finish")
                ] {
                    model.currentStep = step
                    try await UI.wait { UI.contains(L(key), in: host) }
                    try await Task.sleep(for: .milliseconds(300))
                    let button = try UI.button(L(key), in: host)
                    let bottom = button.frame.minY - window.frame.minY
                    #expect(button.frame.height > 0)
                    #expect(bottom >= 24)
                    if let firstBottom { #expect(abs(bottom - firstBottom) <= 1) }
                    else { firstBottom = bottom }
                    if step == .welcome {
                        try UI.snapshot(host, name: "11-native-footer-\(language.rawValue)")
                    }
                }
            }
        }
    }

    @Test func `existing model editor renders inside onboarding sheet`() async throws {
        try await UI.withFixture { settings in
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let manager = OnboardingTestModelManager()
            let model = StudioViewModel(settingsStore: settings, historyStore: OnboardingTestHistoryStore(),
                                        initialSection: .models, localModelManager: manager, modelLibrary: library)
            for (tab, name) in [(ModelPageTab.speech, "09-speech-editor"), (.language, "10-language-editor")] {
                model.selectModelPageTab(tab)
                try await UI.withWindow(StudioView(viewModel: model).onboardingModelEditor.padding(24),
                                        width: 820, height: 550) { _, host in
                    try await capture(host, name: name)
                    #expect(!UI.elements(in: host).isEmpty)
                }
            }
        }
    }
}
