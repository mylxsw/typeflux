import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingComponentTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `shared cards panel guide and footer render in both appearances`() async throws {
        try await UI.withFixture { _ in
            for language in [AppLanguage.english, .simplifiedChinese] {
                AppLocalization.shared.setLanguage(language)
                for dark in [false, true] {
                    var selected = 0
                    var dismissed = false
                    var tested = false
                    var backed = false
                    var advanced = false
                    var deferred = false
                    let back = OnboardingStrings.text("back")
                    let next = OnboardingStrings.text("continue")
                    let later = OnboardingStrings.text("later")
                    let content = ZStack(alignment: .bottomTrailing) {
                        OnboardingBackdrop()
                        VStack(spacing: 20) {
                            OnboardingEditorialHeader(eyebrow: "Voice Recognition",
                                                      title: OnboardingStrings.text("title", table: "OnboardingSpeech"),
                                                      subtitle: OnboardingStrings.text(
                                                          "subtitle",
                                                          table: "OnboardingSpeech"
                                                      ), pill: "01 / 04")
                            HStack(alignment: .top, spacing: 20) {
                                VStack(spacing: 12) {
                                    OnboardingProviderCard(provider: .whisperAPI, title: "OpenAI", detail: "Whisper",
                                                           badge: "API Key", selected: true) { selected += 1 }
                                    OnboardingProviderCard(provider: .ollama, title: "Ollama", selected: false) {
                                        selected += 10
                                    }
                                }.frame(width: 330)
                                OnboardingConfigPanel(eyebrow: "CONFIGURATION", name: "OpenAI",
                                                      provider: .whisperAPI, detail: "Whisper") {
                                    TextField("API Key", text: .constant("")).textFieldStyle(.roundedBorder)
                                        .frame(height: 34)
                                } actions: {
                                    HStack { Text("API Key ↗"); Spacer(); Button(next) { tested = true } }
                                } result: { Text("OK · 120 ms") }
                            }
                            OnboardingFooterBar(back: .init(title: back) { backed = true },
                                                tertiary: .init(title: later) { deferred = true },
                                                primary: .init(title: OnboardingStrings.text("start")) {
                                                    advanced = true
                                                }, hint: "API Key") {
                                EmptyView()
                            }
                        }.padding(34)
                        OnboardingSystemSettingsGuide(title: OnboardingShortcutsModel.text("guideTitle"),
                                                      steps: [OnboardingShortcutsModel.text("guideSetting")],
                                                      dismissTitle: "×") {
                            dismissed = true
                        }
                        .padding(.trailing, 34).padding(.bottom, 110)
                    }.preferredColorScheme(dark ? .dark : .light)
                    try await UI.withWindow(content, width: 960, height: 664) { _, host in
                        try UI.button("OpenAI", in: host).press()
                        try UI.button("Ollama", in: host).press()
                        #expect(selected == 11)
                        try UI.button("×", in: host).press()
                        #expect(dismissed)
                        try UI.button(next, in: host).press()
                        try UI.button(back, in: host).press()
                        try UI.button(later, in: host).press()
                        try UI.button(OnboardingStrings.text("start"), in: host).press()
                        #expect(tested && backed && deferred && advanced)
                        #expect(UI.contains("01 / 04", in: host))
                        try await Task.sleep(for: .milliseconds(150))
                        try UI.snapshot(host, name: "components-\(language.rawValue)-\(dark ? "dark" : "light")")
                    }
                }
            }
        }
    }

    @Test func `optional content and disabled actions stay absent or inactive`() async throws {
        try await UI.withFixture { _ in
            var called = false
            let content = VStack {
                OnboardingEditorialHeader(eyebrow: "Ready", title: "Try it", centered: true)
                OnboardingConfigPanel(eyebrow: "CONFIGURATION", name: "Ollama") {
                    EmptyView()
                } actions: { EmptyView() } result: { EmptyView() }
                OnboardingFooterBar(tertiary: .init(title: "Later", enabled: false) { called = true },
                                    primary: .init(title: "Continue", enabled: false) { called = true }) { EmptyView() }
                OnboardingFooterBar { EmptyView() }
            }.background { OnboardingBackdrop() }
            for dark in [false, true] {
                try await UI
                    .withWindow(content.preferredColorScheme(dark ? .dark : .light), width: 960,
                                height: 664) { _, host in
                        for label in ["Later", "Continue"] {
                            let button = try UI.button(label, in: host)
                            #expect((button.value("isAccessibilityEnabled") as? Bool) == false)
                        }
                        #expect(!called)
                        #expect(!UI.contains("01 / 04", in: host))
                        #expect(!UI.contains("Back", in: host))
                        try UI.snapshot(host, name: "components-empty-disabled-\(dark ? "dark" : "light")")
                    }
            }
        }
    }

    @Test func `native resume opens the first deferred page without resetting shortcuts`() async throws {
        try await UI.withFixture { settings in
            for language in [AppLanguage.english, .simplifiedChinese] {
                settings.appLanguage = language
                AppLocalization.shared.setLanguage(language)
                for appearance in [AppearanceMode.light, .dark] {
                    settings.appearanceMode = appearance
                    for (speech, ai, step) in [(true, true, OnboardingStep.speech),
                                               (false, true, .llm), (false, false, .permissions)] {
                        settings.onboardingSpeechDeferred = speech
                        settings.onboardingAIDeferred = ai
                        settings.activationHotkey = .rightCommandActivation
                        let controller = OnboardingWindowController()
                        controller.show(settingsStore: settings, resume: true, onComplete: {})
                        let window = try #require(controller.window)
                        defer { window.close() }
                        let model = try #require(controller.viewModel)
                        let host = try #require(window.contentView)
                        #expect(model.currentStep == step)
                        #expect(settings.activationHotkey == .rightCommandActivation)
                        try await UI.wait { UI.contains(OnboardingStrings.text("title", table: step.table), in: host) }
                        try await Task.sleep(for: .milliseconds(200))
                        try UI.snapshot(#require(host.superview),
                                        name: "resume-\(step.rawValue)-\(language.rawValue)-\(appearance.rawValue)")
                    }
                }
            }
        }
    }

    @Test func `native window captures include the actual traffic lights`() async throws {
        try await UI.withFixture { settings in
            for language in [AppLanguage.english, .simplifiedChinese] {
                settings.appLanguage = language
                AppLocalization.shared.setLanguage(language)
                for appearance in [AppearanceMode.light, .dark] {
                    settings.appearanceMode = appearance
                    let controller = OnboardingWindowController()
                    controller.show(settingsStore: settings, onComplete: {})
                    let window = try #require(controller.window)
                    defer { window.close() }
                    let frame = try #require(window.contentView?.superview)
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
                    try UI.snapshot(frame, name: "native-window-\(language.rawValue)-\(appearance.rawValue)")
                }
            }
        }
    }
}

extension OnboardingComponentTests {
    @Test func `welcome language menu and close confirmation remain resumable`() async throws {
        try await UI.withFixture { settings in
            for language in [AppLanguage.english, .simplifiedChinese] {
                settings.appLanguage = language
                AppLocalization.shared.setLanguage(language)
                for appearance in [AppearanceMode.light, .dark] {
                    settings.appearanceMode = appearance
                    settings.isOnboardingCompleted = false
                    settings.onboardingSpeechDeferred = false
                    settings.onboardingAIDeferred = false
                    settings.onboardingPermissionsDeferred = false
                    var completions = 0
                    let controller = OnboardingWindowController()
                    controller.show(settingsStore: settings, onComplete: { completions += 1 })
                    let window = try #require(controller.window)
                    defer { window.close() }
                    let host = try #require(window.contentView)
                    try await UI.wait { !UI.elements(in: host).isEmpty }
                    try await captureLanguageMenu(host, suffix: "\(language.rawValue)-\(appearance.rawValue)")
                    window.performClose(nil)
                    try await UI.wait { window.attachedSheet != nil }
                    let sheet = try #require(window.attachedSheet)
                    window.performClose(nil)
                    #expect(window.attachedSheet === sheet)
                    try await Task.sleep(for: .milliseconds(500))
                    try UI.snapshotNativeWindow(window, overlays: [sheet],
                                                name: "welcome-close-\(language.rawValue)-\(appearance.rawValue)")
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    sheet.close()
                    try await UI.wait { window.attachedSheet == nil }
                    try await Task.sleep(for: .milliseconds(50))
                    #expect(controller.window === window && !settings.isOnboardingCompleted)
                    #expect(completions == 0)
                    #expect(!settings.onboardingSpeechDeferred && !settings.onboardingAIDeferred
                        && !settings.onboardingPermissionsDeferred)
                    let session = try #require(controller.viewModel)
                    session.speechSkipped = true
                    session.aiSkipped = true
                    session.permissions = []
                    window.performClose(nil)
                    try await UI.wait { window.attachedSheet != nil }
                    let exit = try #require(window.attachedSheet)
                    window.endSheet(exit, returnCode: .alertSecondButtonReturn)
                    exit.close()
                    try await UI.wait { controller.window == nil }
                    #expect(settings.isOnboardingCompleted && completions == 1)
                    #expect(settings.onboardingSpeechDeferred && settings.onboardingAIDeferred
                        && settings.onboardingPermissionsDeferred)
                }
            }
        }
    }

    private func captureLanguageMenu(_ host: NSView, suffix: String) async throws {
        try await UI.captureMenu(in: host, identifier: "onboarding.language", name: "welcome-language-\(suffix)")
    }
}
