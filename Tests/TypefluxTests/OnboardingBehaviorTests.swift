import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingBehaviorTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func fixture(language: AppLanguage = .english, appearance: AppearanceMode = .light,
                         _ check: (SettingsStore, OnboardingViewModel, NSView) async throws -> Void) async throws {
        try await UI.withFixture { settings in
            settings.appLanguage = language
            AppLocalization.shared.setLanguage(language)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let model = OnboardingViewModel(settingsStore: settings, modelLibrary: library,
                                            globeKeyReader: OnboardingReadyGlobeKey(),
                                            localModelManager: OnboardingTestModelManager(), onComplete: {})
            try await UI.withWindow(OnboardingView(viewModel: model, appearanceMode: appearance),
                                    width: 960, height: 664) { window, host in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                try await check(settings, model, host)
            }
        }
    }

    private func capture(_ host: NSView, name: String) async throws {
        try await Task.sleep(for: .milliseconds(150))
        try UI.snapshot(host, name: name)
    }

    @Test func `welcome route selection back and skip are wired through native buttons`() async throws {
        try await fixture { settings, model, host in
            try UI.button(OnboardingStrings.text("start"), in: host).press()
            try await UI.wait {
                model.currentStep == .route
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.route.table), in: host)
            }
            try await UI.wait { UI.contains(OnboardingStrings.text("title", table: "OnboardingRoute"), in: host) }
            try UI.button(OnboardingStrings.text("customTitle", table: "OnboardingRoute"), in: host).press()
            #expect(model.serviceRoute == .custom)
            try UI.button(OnboardingStrings.text("continue"), in: host).press()
            try await UI.wait {
                model.currentStep == .speech
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.speech.table), in: host)
            }
            try UI.button(OnboardingStrings.text("back"), in: host).press()
            try await UI.wait {
                model.currentStep == .route
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.route.table), in: host)
            }
            try UI.button("Typeflux Cloud", in: host).press()
            try UI.button(OnboardingStrings.text("continue"), in: host).press()
            try await UI.wait {
                model.currentStep == .cloud
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.cloud.table), in: host)
            }
            try UI.button(OnboardingStrings.text("custom"), in: host).press()
            try await UI.wait {
                model.currentStep == .speech
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.speech.table), in: host)
            }
            try UI.button(OnboardingStrings.text("later"), in: host).press()
            #expect(model.skipConfirmation == .speech)
            model.confirmSkip()
            try await UI.wait {
                model.currentStep == .llm
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.llm.table), in: host)
            }
            try UI.button(OnboardingStrings.text("skip"), in: host).press()
            model.confirmSkip()
            try await UI.wait {
                model.currentStep == .permissions
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.permissions.table), in: host)
            }
            try UI.button(OnboardingStrings.text("later"), in: host).press()
            model.confirmSkip()
            try await UI.wait {
                model.currentStep == .shortcuts
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.shortcuts.table), in: host)
            }
            try UI.button(OnboardingStrings.text("continue"), in: host).press()
            try await UI.wait {
                model.currentStep == .try
                    && UI.contains(OnboardingStrings.text("title", table: OnboardingStep.try.table), in: host)
            }
            try UI.button(OnboardingStrings.text("finish"), in: host).press()
            #expect(settings.isOnboardingCompleted)
            #expect(settings.onboardingSpeechDeferred && settings.onboardingAIDeferred)
            #expect(settings.onboardingPermissionsDeferred)
        }
    }

    @Test func `every page has fixed stage chrome in both languages and appearances`() async throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            for appearance in [AppearanceMode.light, .dark] {
                try await fixture(language: language, appearance: appearance) { _, model, host in
                    for step in OnboardingStep.allCases {
                        model.chooseRoute(step == .cloud ? .cloud : .custom)
                        model.currentStep = step
                        if step != .welcome {
                            try await UI
                                .wait { UI.contains(OnboardingStrings.text("title", table: step.table), in: host) }
                            #expect(try UI.contains(#require(step.pill), in: host))
                        }
                        #expect(host.bounds.size == NSSize(width: 960, height: 664))
                        let primary = try UI.button(OnboardingStrings.text(
                            step == .welcome ? "start" : step == .try ? "finish" : "continue"
                        ), in: host)
                        #expect(primary.frame.height >= 38)
                        try await capture(host, name: "\(step.rawValue)-\(language.rawValue)-\(appearance.rawValue)")
                    }
                    model.currentStep = .route
                    model.chooseRoute(.cloud)
                    try await capture(host, name: "route-cloud-\(language.rawValue)-\(appearance.rawValue)")
                    try UI.button(OnboardingStrings.text("skipAll"), in: host).press()
                    #expect(model.skipConfirmation == .allModels)
                    model.skipConfirmation = nil
                }
            }
        }
    }

    @Test func `inline adapter enables the primary without opening a modal editor`() async throws {
        try await fixture { _, model, host in
            model.chooseRoute(.custom)
            model.currentStep = .speech
            var called = false
            model.speechModel.primaryAction = { called = true }
            model.speechModel.canContinue = false
            try await UI.wait { UI.contains(OnboardingStrings.text("title", table: "OnboardingSpeech"), in: host) }
            try UI.button(OnboardingStrings.text("continue"), in: host).press()
            #expect(called)
            #expect(host.window?.attachedSheet == nil)
            model.speechModel.primaryAction = nil
        }
    }

    @Test func `window controller keeps native title bar and resume entry`() async throws {
        try await UI.withFixture { settings in
            settings.onboardingSpeechDeferred = true
            let controller = OnboardingWindowController()
            var completed = 0
            controller.show(settingsStore: settings, resume: true) { completed += 1 }
            let window = try #require(controller.window)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.contentView?.bounds.size == NSSize(width: 960, height: 664))
            #expect(controller.viewModel?.currentStep == .speech)
            controller.bringToFront()
            controller.show(settingsStore: settings) { completed += 10 }
            #expect(controller.window === window)
            window.close()
            #expect(controller.window == nil)
            #expect(completed == 1)
        }
    }
}
