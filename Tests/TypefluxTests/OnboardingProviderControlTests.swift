import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension OnboardingSpeechLLMTests {
    @Test func `native provider and test buttons drive the same persisted setup`() async throws {
        try await fixture { settings, session, manager, _, _ in
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                let free = OnboardingStrings.text("provider.free.title", table: "OnboardingSpeech")
                let soniox = OnboardingStrings.text("provider.soniox.title", table: "OnboardingSpeech")
                try await Controls.wait { Controls.contains(soniox, in: host) }
                #expect(!Controls.contains(free, in: host))
                try Controls.button(soniox, in: host).press()
                #expect(session.speechModel.selectedProvider == .soniox)
                #expect(settings.sttProvider == .soniox)
                let local = OnboardingStrings.text("provider.local.title", table: "OnboardingSpeech")
                try Controls.button(local, in: host).press()
                manager.available = false
                session.speechModel.objectWillChange.send()
                let download = OnboardingStrings.text("local.download", table: "OnboardingSpeech")
                try await Controls.wait { Controls.contains(download, in: host) }
                try Controls.button(download, in: host).press()
                try await Controls.wait { manager.available }
                #expect(session.speechModel.canContinue == false)
                session.currentStep = .llm
                try await Controls.wait {
                    Controls.contains(OnboardingStrings.text("title", table: "OnboardingLlm"), in: host)
                        && !Controls.contains(OnboardingStrings.text("title", table: "OnboardingSpeech"), in: host)
                }
                let openAI = OnboardingStrings.text("provider.openai.title", table: "OnboardingLlm")
                try await Controls.wait { Controls.contains(openAI, in: host) }
                #expect(!Controls.contains(OnboardingStrings.text("provider.free.title", table: "OnboardingLlm"),
                                           in: host))
                try Controls.button(openAI, in: host).press()
                #expect(session.llmModel.selectedProvider == .remote(.openAI))
                session.llmModel.apiKey = "fixture"
                try await Controls.wait { session.llmModel.validationStatus == .valid }
                let test = OnboardingStrings.text("action.testConnection", table: "OnboardingLlm")
                try await Controls.wait { Controls.contains(test, in: host) }
                try Controls.button(test, in: host).press()
                try await Controls.wait {
                    if case .success = session.llmModel.testStatus { return true }
                    return false
                }
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference) != nil)
            }
        }
    }
}

extension OnboardingSpeechLLMTests {
    private func nativeButtons(_ view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(nativeButtons)
    }

    @Test func `Doubao setup exposes editable resource and native presets in both appearances`() async throws {
        try await fixture { settings, session, _, _, _ in
            let model = session.speechModel
            model.selectProvider(.doubaoRealtime)
            for language in [AppLanguage.english, .simplifiedChinese] {
                AppLocalization.shared.setLanguage(language)
                for appearance in [AppearanceMode.light, .dark] {
                    try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: appearance),
                                                  width: 960, height: 664, nativeWindow: true) { window, host in
                        window.appearance = AppAppearance.nsAppearance(for: appearance)
                        try await Controls.wait { nativeButtons(host).contains {
                            $0.accessibilityIdentifier() == "onboarding.speech.doubaoResourcePresets"
                        } }
                        let editable = Controls.elements(in: host).first {
                            $0.value("accessibilityIdentifier") as? String == "onboarding.speech.doubaoResourceID"
                        }
                        #expect(editable != nil)
                        #expect(try #require(editable).frame.intersects(window.frame))
                        let help = try #require(Controls.elements(in: host).first {
                            $0.value("accessibilityIdentifier") as? String == "onboarding.speech.doubaoResourceHelp"
                        })
                        let hint = OnboardingStrings.text("doubao.resourceHint", table: "OnboardingSpeech")
                        #expect(help.label == hint)
                        #expect(help.value("accessibilityHelp") as? String == hint)
                        #expect(!Controls.elements(in: host).contains {
                            $0.role == NSAccessibility.Role.staticText.rawValue && $0.text == hint
                        })
                        #expect(Controls.contains(
                            OnboardingStrings.text("doubao.guideTitle", table: "OnboardingSpeech"),
                            in: host
                        ))
                        let menu = try #require(nativeButtons(host).first {
                            $0.accessibilityIdentifier() == "onboarding.speech.doubaoResourcePresets"
                        })
                        let resource = "volc.seedasr.sauc.concurrent"
                        try menu.select(#require(menu.itemArray.first { $0.representedObject as? String == resource }))
                        #expect(try NSApp.sendAction(#require(menu.action), to: menu.target, from: menu))
                        #expect(model.doubaoResourceID == resource && settings.doubaoResourceID == resource)
                        try await Task.sleep(for: .milliseconds(100))
                        try Controls.snapshot(host, name: "doubao-setup-\(language.rawValue)-\(appearance.rawValue)")
                        let guideTitle = OnboardingStrings.text("doubao.guideTitle", table: "OnboardingSpeech")
                        try Controls.button(guideTitle, in: host).press()
                        try await Controls.wait {
                            Controls.contains(
                                OnboardingStrings.text("doubao.guideCredentials", table: "OnboardingSpeech"),
                                in: host
                            )
                        }
                        try await Task.sleep(for: .milliseconds(150))
                        try Controls.snapshot(host, name: "doubao-guide-\(language.rawValue)-\(appearance.rawValue)")
                    }
                }
            }
        }
    }

    @Test func `speech test feedback stays fully visible outside the configuration scroll area`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.speechModel
            model.selectProvider(.doubaoRealtime)
            model.doubaoAppID = "fixture-app"
            model.doubaoAccessToken = "fixture-token"
            for language in [AppLanguage.english, .simplifiedChinese] {
                AppLocalization.shared.setLanguage(language)
                for appearance in [AppearanceMode.light, .dark] {
                    try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: appearance),
                                                  width: 960, height: 664, nativeWindow: true) { window, host in
                        window.appearance = AppAppearance.nsAppearance(for: appearance)
                        let guide = OnboardingStrings.text("doubao.guideTitle", table: "OnboardingSpeech")
                        try await Controls.wait { Controls.contains(guide, in: host) }
                        let states: [(OnboardingSpeechModel.TestStatus, String)] = [
                            (.recording, OnboardingStrings.text("status.listening", table: "OnboardingSpeech")),
                            (.recognizing, OnboardingStrings.text("status.recognizing", table: "OnboardingSpeech")),
                            (.failure(message: "Fixture connection error"), "Fixture connection error"),
                            (.success(preview: "Meeting tomorrow at three", latencyMs: 640),
                             "「Meeting tomorrow at three」")
                        ]
                        for expanded in [false, true] {
                            if expanded { try Controls.button(guide, in: host).press() }
                            for (status, text) in states {
                                model.testStatus = status
                                try await Controls.wait { Controls.contains(text, in: host) }
                                host.layoutSubtreeIfNeeded()
                                let feedback = try #require(Controls.elements(in: host).first { $0.text == text })
                                let button = try Controls.button(
                                    OnboardingStrings.text("action.testHoldToTalk", table: "OnboardingSpeech"),
                                    in: host
                                )
                                let content = window.convertToScreen(host.convert(host.bounds, to: nil))
                                #expect(feedback.frame.height > 0 && content.contains(feedback.frame))
                                #expect(content.contains(button.frame))
                                #expect(feedback.frame.maxY < button.frame.minY)
                                let scrolls = configurationScrollViews(in: host)
                                #expect(!scrolls.isEmpty)
                                for scroll in scrolls {
                                    let viewport = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                                    #expect(!viewport.intersects(feedback.frame))
                                }
                            }
                            try Controls.snapshot(host, name:
                                "doubao-feedback-\(expanded ? "expanded" : "collapsed")-\(language.rawValue)-\(appearance.rawValue)")
                        }
                        model.testStatus = .idle
                    }
                }
            }
        }
    }

    private func configurationScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { configurationScrollViews(in: $0) }
    }

    @Test func `native speech model menu persists the selected model`() async throws {
        try await fixture { settings, session, _, _, _ in
            session.speechModel.selectProvider(.localModel)
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                try await Controls.wait { nativeButtons(host).contains {
                    $0.accessibilityIdentifier() == "onboarding.speech.model"
                } }
                let button = try #require(nativeButtons(host).first {
                    $0.accessibilityIdentifier() == "onboarding.speech.model"
                })
                let next = try #require(LocalSTTModel.displayOrder
                    .first { $0 != session.speechModel.selectedLocalModel })
                let item = try #require(button.itemArray.first { $0.representedObject as? String == next.rawValue })
                button.select(item)
                #expect(try NSApp.sendAction(#require(button.action), to: button.target, from: button))
                #expect(settings.localSTTModel == next && session.speechModel.selectedLocalModel == next)
                #expect(button.bounds.width > 200, "The native hit target fills the editorial field")
            }
        }
    }

    @Test func `native LLM menu updates the registry and disables an empty catalog`() async throws {
        try await fixture { _, session, _, catalog, _ in
            session.currentStep = .llm
            let model = session.llmModel
            model.selectProvider(.remote(.openAI))
            model.apiKey = "fixture"
            try await Controls.wait { model.validationStatus == .valid }
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                try await Controls.wait { nativeButtons(host).contains {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                } }
                let button = try #require(nativeButtons(host).first {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                })
                let next = try #require(model.availableModels.first { $0 != model.selectedModel })
                try button.select(#require(button.itemArray.first { $0.representedObject as? String == next }))
                #expect(try NSApp.sendAction(#require(button.action), to: button.target, from: button))
                #expect(model.selectedModel == next)
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.1.id == next)
                catalog.ids = []
                model.apiKey = "another-fixture"
                try await Controls.wait { model.validationStatus == .invalid(message: L("models.noModels")) }
                try await Controls.wait { nativeButtons(host).contains {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                        && !$0.isEnabled && $0.numberOfItems == 0
                } }
                let empty = try #require(nativeButtons(host).first {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                })
                #expect(empty.selectedItem == nil && model.canContinue == false)
                let reference = session.modelLibrary.rewriteReference
                _ = try NSApp.sendAction(#require(empty.action), to: empty.target, from: empty)
                #expect(session.modelLibrary.rewriteReference == reference)
            }
        }
    }
}

extension OnboardingSpeechLLMTests {
    func captureMenus(_ session: OnboardingViewModel, host: NSView, suffix: String) async throws {
        session.currentStep = .speech
        session.speechModel.selectProvider(.localModel)
        try await Controls.wait {
            Controls.contains(OnboardingStrings.text("title", table: "OnboardingSpeech"), in: host)
                && !Controls.contains(OnboardingStrings.text("title", table: "OnboardingLlm"), in: host)
        }
        try await captureNativeMenu(
            in: host,
            identifier: "onboarding.speech.model",
            name: "speech-model-menu-\(suffix)"
        )
        session.currentStep = .llm
        session.llmModel.selectProvider(.remote(.openAI))
        session.llmModel.apiKey = "fixture"
        try await Controls.wait { session.llmModel.validationStatus == .valid }
        try await Controls.wait {
            nativeButtons(host).contains { $0.accessibilityIdentifier() == "onboarding.llm.model" }
                && !nativeButtons(host).contains { $0.accessibilityIdentifier() == "onboarding.speech.model" }
        }
        try await captureNativeMenu(in: host, identifier: "onboarding.llm.model", name: "llm-model-menu-\(suffix)")
        try await captureNativeMenu(
            in: host,
            identifier: "onboarding.llm.moreProviders",
            name: "llm-more-menu-\(suffix)"
        )
    }

    private func captureNativeMenu(in host: NSView, identifier: String, name: String) async throws {
        try await Controls.captureMenu(in: host, identifier: identifier, name: name)
    }
}
