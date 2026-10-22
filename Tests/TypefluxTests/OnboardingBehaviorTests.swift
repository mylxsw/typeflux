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

    @Test func `welcome leads to goals and goal tiles toggle the plan`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.useAppleSpeechFallback = false
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(), onComplete: {})
            try await withOnboardingWindow(model, appearance: .dark) { window, host in
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.welcome.lead"), in: host) }
                try RenderedUI.snapshot(host, name: "onboarding-welcome")
                let start = try RenderedUI.button(L("onboarding.v2.action.start"), in: host)
                #expect(window.frame.contains(start.frame))
                try start.press()
                try await RenderedUI.wait { model.currentStep == .goals }
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.plan.summary", 3, 5), in: host) }

                try RenderedUI.button(OnboardingGoal.ring.title, in: host).press()
                try await RenderedUI.wait { model.goals.contains(.ring) }
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.v2.plan.summary", 4, 6), in: host) }
                try RenderedUI.snapshot(host, name: "onboarding-goals")

                try RenderedUI.button(L("onboarding.v2.goals.all.title"), in: host).press()
                try await RenderedUI.wait { model.allGoalsSelected }
                try RenderedUI.button(L("onboarding.v2.goals.all.title"), in: host).press()
                try await RenderedUI.wait { model.goals == OnboardingGoal.defaultSelection }

                try RenderedUI.button(L("onboarding.v2.action.continue"), in: host).press()
                try await RenderedUI.wait { model.currentStep == .permissions }
                try RenderedUI.button(L("onboarding.v2.action.back"), in: host).press()
                try await RenderedUI.wait { model.currentStep == .goals }
            }
        }
    }

    @Test func `permissions list follows goals and later finishes without blocking`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.useAppleSpeechFallback = false
            var completions = 0
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(),
                                            onComplete: { completions += 1 })
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
                #expect(!RenderedUI.contains(L("onboarding.v2.globe.title"), in: host))
                try RenderedUI.snapshot(host, name: "onboarding-permissions")

                let finish = try RenderedUI.button(L("onboarding.v2.action.finish"), in: host)
                #expect(!model.canAdvance, "Finishing waits for the required permissions")
                #expect(finish.value("isAccessibilityEnabled") as? Bool != true)
                #expect(!settings.isOnboardingCompleted)

                try RenderedUI.button(L("onboarding.v2.action.later"), in: host).press()
                try await RenderedUI.wait { settings.isOnboardingCompleted }
                #expect(completions == 1)
                #expect(settings.onboardingGoals == OnboardingGoal.defaultSelection)
            }
        }
    }

    @Test func `granted permissions finish and blocked fn key offers fixes`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.useAppleSpeechFallback = false
            var completions = 0
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: BlockedGlobeKey(),
                                            onComplete: { completions += 1 })
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

                try RenderedUI.button(L("onboarding.v2.action.finish"), in: host).press()
                try await RenderedUI.wait { settings.isOnboardingCompleted }
                #expect(completions == 1)
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
                    OnboardingWelcomeHero.Scene.allCases.contains { RenderedUI.contains($0.caption, in: host) }
                }
                try RenderedUI.snapshot(host, name: "onboarding-welcome-zh")
            }
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
