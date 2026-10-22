import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Onboarding rendered behavior", .serialized, .exclusiveUIState)
@MainActor
struct OnboardingBehaviorTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport
    private static let size = CGSize(width: OnboardingWindowController.windowWidth,
                                     height: OnboardingWindowController.windowHeight)

    @Test func `welcome leads through permissions every guide and the finish page`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.useAppleSpeechFallback = false
            var completions = 0
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(),
                                            onComplete: { completions += 1 })
            try await withOnboardingWindow(model, appearance: .dark) { window, host in
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.welcome.lead"), in: host) }
                try RenderedUI.snapshot(host, name: "onboarding-welcome")
                let start = try RenderedUI.button(L("onboarding.v2.action.start"), in: host)
                #expect(window.frame.contains(start.frame))
                try start.press()
                try await RenderedUI.wait { model.currentStep == .permissions }

                model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(id: $0, state: .granted, detail: "Granted") }
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.permissions.title.ready"), in: host) }
                try RenderedUI.button(L("onboarding.v2.action.continue"), in: host).press()

                for feature in OnboardingFeature.allCases {
                    try await RenderedUI.wait { model.currentStep.feature == feature }
                    try await RenderedUI.wait { RenderedUI.contains(feature.caption, in: host) }
                    try RenderedUI.button(L("onboarding.v2.action.next"), in: host).press()
                }
                try await RenderedUI.wait { model.currentStep == .finish }
                try RenderedUI.button(L("onboarding.v2.action.back"), in: host).press()
                try await RenderedUI.wait { model.currentStep == .chat }
                try RenderedUI.button(L("onboarding.v2.action.next"), in: host).press()
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.finish.title"), in: host) }

                try RenderedUI.button(L("onboarding.v2.action.finish"), in: host).press()
                try await RenderedUI.wait { settings.isOnboardingCompleted }
                #expect(completions == 1)
            }
        }
    }

    @Test func `permissions ask for every feature and later moves on to the guides`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.useAppleSpeechFallback = false
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(), onComplete: {})
            model.currentStep = .permissions
            model.permissions = [
                .init(id: .microphone, state: .needsAttention, detail: "Fixture missing microphone"),
                .init(id: .speechRecognition, state: .granted, detail: "Fixture speech"),
                .init(id: .accessibility, state: .granted, detail: "Fixture accessibility")
            ]
            try await withOnboardingWindow(model, appearance: .light) { _, host in
                try await RenderedUI.wait {
                    RenderedUI.contains(L("onboarding.v2.permissions.title.missing", 1), in: host)
                }
                #expect(RenderedUI.contains(L("onboarding.v2.permission.microphone.detail"), in: host))
                #expect(RenderedUI.contains(L("onboarding.v2.permission.accessibility.detail"), in: host))
                #expect(!RenderedUI.contains(L("onboarding.v2.permission.speechRecognition.detail"), in: host))
                #expect(RenderedUI.contains(OnboardingFeature.ring.title, in: host), "Chips name every feature")
                #expect(!RenderedUI.contains(L("onboarding.v2.globe.title"), in: host))
                try RenderedUI.snapshot(host, name: "onboarding-permissions")

                let next = try RenderedUI.button(L("onboarding.v2.action.continue"), in: host)
                #expect(!model.canAdvance, "Continuing waits for the required permissions")
                #expect(next.value("isAccessibilityEnabled") as? Bool != true)

                try RenderedUI.button(L("onboarding.v2.action.later"), in: host).press()
                try await RenderedUI.wait { model.currentStep == .voice }
                #expect(!settings.isOnboardingCompleted, "Later skips permissions, not the guides")
            }
        }
    }

    @Test func `granted permissions continue and blocked fn key offers fixes`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.useAppleSpeechFallback = false
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: BlockedGlobeKey(), onComplete: {})
            model.currentStep = .permissions
            model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(id: $0, state: .granted, detail: "Granted") }
            try await withOnboardingWindow(model, appearance: .dark) { _, host in
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.permissions.title.ready"), in: host) }
                #expect(RenderedUI.contains(L("onboarding.v2.globe.title"), in: host))
                #expect(RenderedUI.contains(L("onboarding.v2.globe.detail"), in: host))
                #expect(!RenderedUI.contains(L("onboarding.v2.action.later"), in: host))
                try RenderedUI.snapshot(host, name: "onboarding-permissions-ready")

                model.useExternalKeyboardShortcutReplacement(.rightCommand)
                model.showShortcutReplacementAppliedAlert = false
                try await RenderedUI.wait { !RenderedUI.contains(L("onboarding.v2.globe.title"), in: host) }

                try RenderedUI.button(L("onboarding.v2.action.continue"), in: host).press()
                try await RenderedUI.wait { model.currentStep == .voice }
            }
        }
    }

    @Test func `voice guide shows its keys and confirms practice`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(), onComplete: {})
            model.currentStep = .voice
            try await withOnboardingWindow(model, appearance: .light) { _, host in
                let placeholder = L("onboarding.v2.voice.practice.placeholder", HotkeyFormat.display(.defaultActivation))
                try await RenderedUI.wait { RenderedUI.contains(placeholder, in: host) }
                #expect(RenderedUI.contains(L("onboarding.tip.voice.talk"), in: host))
                #expect(RenderedUI.contains(L("onboarding.tip.voice.rewrite"), in: host))
                #expect(RenderedUI.contains("1 / 5", in: host))
                #expect(!RenderedUI.contains(L("onboarding.v2.voice.practice.done"), in: host))

                model.voicePracticeText = "Send me the deck by Friday."
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.voice.practice.done"), in: host) }
                try RenderedUI.snapshot(host, name: "onboarding-voice")
            }
        }
    }

    @Test func `each guide opened directly shows its keys`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.setHotkey(nil, for: .ring)
            for feature in [OnboardingFeature.launcher, .tools, .ring, .chat] {
                let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(), onComplete: {})
                model.currentStep = OnboardingViewModel.Step.allCases.first { $0.feature == feature } ?? .voice
                try await withOnboardingWindow(model, appearance: .dark) { _, host in
                    try await RenderedUI.wait { RenderedUI.contains(feature.caption, in: host) }
                    for shortcut in feature.shortcuts(settingsStore: settings) {
                        #expect(RenderedUI.contains(shortcut.title, in: host), "\(shortcut.id)")
                    }
                    if feature == .ring {
                        #expect(RenderedUI.contains(L("onboarding.v2.shortcut.notSet"), in: host))
                    }
                    // Captured without a step transition so the snapshot shows the settled screen.
                    try RenderedUI.snapshot(host, name: "onboarding-\(feature.rawValue)")
                }
            }
        }
    }

    @Test func `finish page lists a key for every feature`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(), onComplete: {})
            model.currentStep = .finish
            try await withOnboardingWindow(model, appearance: .light) { _, host in
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.finish.title"), in: host) }
                for feature in OnboardingFeature.allCases {
                    #expect(RenderedUI.contains(feature.title, in: host))
                }
                try RenderedUI.snapshot(host, name: "onboarding-finish")
            }
        }
    }

    @Test func `language menu shows the chosen language`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(), onComplete: {})
            try await withOnboardingWindow(model, appearance: .light) { _, host in
                try await RenderedUI.wait { RenderedUI.contains(AppLanguage.english.displayName, in: host) }
                model.setLanguage(.simplifiedChinese)
                try await RenderedUI.wait { RenderedUI.contains(AppLanguage.simplifiedChinese.displayName, in: host) }
                #expect(SettingsStore(defaults: settings.defaults).appLanguage == .simplifiedChinese)
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.welcome.lead"), in: host) }
                try await RenderedUI.wait {
                    OnboardingWelcomeHero.Scene.welcome.contains { RenderedUI.contains($0.caption, in: host) }
                }
                try RenderedUI.snapshot(host, name: "onboarding-welcome-zh")
            }
        }
    }

    @Test func `every scene renders its caption`() async throws {
        try await RenderedUI.withFixture { _ in
            for scene in OnboardingWelcomeHero.Scene.allCases {
                try await RenderedUI.withWindow(OnboardingWelcomeHero(scene: scene), width: 480, height: 520) { _, host in
                    try await RenderedUI.wait { RenderedUI.contains(scene.caption, in: host) }
                }
                #expect(!scene.symbol.isEmpty && !scene.caption.hasPrefix("onboarding."))
            }
            for scene in OnboardingWelcomeHero.Scene.welcome {
                #expect(!scene.verb.hasPrefix("onboarding.") && !scene.featureName.hasPrefix("onboarding."))
            }
            #expect(OnboardingFeature.allCases.map(OnboardingWelcomeHero.Scene.init) == OnboardingWelcomeHero.Scene.allCases)
        }
    }

    private func withOnboardingWindow(
        _ model: OnboardingViewModel,
        appearance: AppearanceMode,
        check: (NSWindow, NSView) async throws -> Void
    ) async throws {
        try await RenderedUI.withWindow(
            OnboardingView(viewModel: model, appearanceMode: appearance),
            width: Self.size.width, height: Self.size.height,
            check: check
        )
    }
}

private struct ReadyGlobeKey: GlobeKeyPreferenceReading {
    func currentUsage() -> GlobeKeyUsage? {
        .doNothing
    }
}

private struct BlockedGlobeKey: GlobeKeyPreferenceReading {
    func currentUsage() -> GlobeKeyUsage? {
        .showEmojiAndSymbols
    }
}
