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
                        OnboardingSystemSettingsGuide(title: L("onboarding.v2.globe.title"),
                                                      steps: [L("onboarding.v2.globe.detail")], dismissTitle: "×") {
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

    @Test func `retained guides still read live shortcuts and practice completion`() async throws {
        try await UI.withFixture { settings in
            let manager = OnboardingTestModelManager()
            manager.available = true
            settings.activationHotkey = .rightCommandActivation
            let model = OnboardingViewModel(settingsStore: settings,
                                            modelLibrary: AskModelLibrary(
                                                defaults: settings.defaults,
                                                automaticallyLoadsCatalog: false
                                            ),
                                            globeKeyReader: OnboardingReadyGlobeKey(), localModelManager: manager,
                                            onComplete: {})
            model.permissions = []
            for feature in OnboardingFeature.allCases {
                try await UI.withWindow(OnboardingLegacyGuidePage(viewModel: model, feature: feature),
                                        width: 960, height: 550) { _, host in
                    #expect(UI.contains(feature.title, in: host))
                    if feature == .voice {
                        let link = try #require(UI.elements(in: host).first {
                            $0.label == L("setup.action.permissions") && $0.role == NSAccessibility.Role.link.rawValue
                        })
                        try link.press()
                        #expect(model.currentStep == .permissions)
                    }
                }
            }
            model.permissions = PrivacyGuard.PermissionID.allCases.map {
                .init(id: $0, state: .granted, detail: "Granted")
            }
            try await UI.withWindow(OnboardingLegacyGuidePage(viewModel: model, feature: .voice),
                                    width: 960, height: 550) { _, host in
                #expect(UI.contains(L("onboarding.v2.voice.practice.placeholder",
                                      HotkeyFormat.display(.rightCommandActivation)), in: host))
                model.voicePracticeText = "Hello"
                model.voicePracticeSucceeded = true
                try await UI.wait { UI.contains(L("onboarding.v2.voice.practice.done"), in: host) }
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
                    defer { window.performClose(nil) }
                    let frame = try #require(window.contentView?.superview)
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
                    try UI.snapshot(frame, name: "native-window-\(language.rawValue)-\(appearance.rawValue)")
                }
            }
        }
    }
}
