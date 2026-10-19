import AppKit
import SwiftUI
import Testing
@testable import Typeflux

struct VoiceCapsulePreferencesTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "VoiceCapsulePreferencesTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func defaultsKeepTheOriginalCapsule() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SettingsStore(defaults: defaults).voiceCapsule
        #expect(preferences == VoiceCapsulePreferences())
        #expect(preferences.style == .bottomCapsule)
        #expect(preferences.screen == .activeWindow)
        #expect(preferences.cornerEdge == .trailing)
        #expect(preferences.notchFallback == .simulateNotch)
        #expect(preferences.notchHoverExpands && preferences.showsLivePreview && preferences.showsTargetApp)
    }

    @Test func storeRoundTripsAndNotifiesOnlyOnChange() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: .voiceCapsuleDidChange, object: store,
                                                           queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        var preferences = VoiceCapsulePreferences()
        preferences.style = .notchIsland
        preferences.cornerEdge = .leading
        preferences.notchFallback = .cornerCard
        preferences.notchHoverExpands = false
        preferences.showsLivePreview = false
        preferences.showsTargetApp = false
        preferences.screen = .mouse
        store.voiceCapsule = preferences
        store.voiceCapsule = preferences

        #expect(notifications == 1)
        #expect(SettingsStore(defaults: defaults).voiceCapsule == preferences)
        #expect(defaults.string(forKey: VoiceCapsulePreferences.Key.style) == "notchIsland")
    }

    @Test func unknownStoredValuesFallBackToDefaults() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("hologram", forKey: VoiceCapsulePreferences.Key.style)
        defaults.set("middle", forKey: VoiceCapsulePreferences.Key.cornerEdge)
        defaults.set("teleport", forKey: VoiceCapsulePreferences.Key.notchFallback)
        defaults.set("moon", forKey: VoiceCapsulePreferences.Key.screen)
        defaults.set("yes", forKey: VoiceCapsulePreferences.Key.showsLivePreview)
        #expect(VoiceCapsulePreferences(defaults: defaults) == VoiceCapsulePreferences())
    }
}

@Suite(.serialized, .exclusiveUIState)
struct VoiceCapsuleCopyTests {
    private func withEnglish(_ body: () throws -> Void) rethrows {
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        AppLocalization.shared.setLanguage(.english)
        try body()
    }

    @Test func statesAndSubtitles() {
        withEnglish {
            var snapshot = VoiceCapsuleSnapshot(phase: .listening(handsFree: false), targetAppName: "Notes")
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Listening · Notes")
            snapshot.phase = .listening(handsFree: true)
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Hands-free · Notes")
            snapshot.phase = .processing
            #expect(VoiceCapsuleCopy.state(for: snapshot) == L("overlay.processing.thinking"))
            snapshot.statusText = "Polishing"
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Polishing · Notes")
            snapshot.phase = .completed
            snapshot.completedCharacterCount = 35
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Inserted · Notes · 35 characters")
            snapshot.completedCharacterCount = 0
            snapshot.targetAppName = nil
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Inserted")
            snapshot.phase = .failure
            snapshot.statusText = ""
            snapshot.targetAppName = "Notes"
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == L("overlay.failure.title"))
            snapshot.statusText = "Timed out"
            #expect(VoiceCapsuleCopy.state(for: snapshot) == "Timed out")
        }
    }

    @Test func hintsAndPercentages() {
        withEnglish {
            #expect(VoiceCapsuleCopy.hint(for: .listening(handsFree: false)) == "Release the shortcut to insert")
            #expect(VoiceCapsuleCopy.hint(for: .listening(handsFree: true)).hasPrefix("Press the shortcut again"))
            #expect(VoiceCapsuleCopy.percent(0.624) == "62%")
            #expect(VoiceCapsuleCopy.percent(-1) == "0%")
            #expect(VoiceCapsuleCopy.percent(3) == "100%")
        }
    }

    @Test func everyOptionHasALocalizedName() {
        withEnglish {
            let names = VoiceCapsuleStyle.allCases.flatMap { [$0.displayName, $0.detail] }
                + VoiceCapsuleCornerEdge.allCases.map(\.displayName)
                + VoiceCapsuleNotchFallback.allCases.map(\.displayName)
                + VoiceCapsuleScreenChoice.allCases.map(\.displayName)
            for name in names {
                #expect(!name.isEmpty && !name.hasPrefix("voiceCapsule."), "Missing translation: \(name)")
            }
            #expect(Set(names).count == names.count)
        }
    }

    @Test func cardControlsDependOnThePhase() {
        #expect(VoiceCapsulePhase.listening(handsFree: false).cardControls == [.cancel])
        #expect(VoiceCapsulePhase.listening(handsFree: true).cardControls == [.cancel, .confirm])
        #expect(VoiceCapsulePhase.processing.cardControls == [.cancel])
        #expect(VoiceCapsulePhase.completed.cardControls.isEmpty)
        #expect(VoiceCapsulePhase.failure.cardControls.isEmpty)
        #expect(VoiceCapsuleSkin.cornerCard(.leading).isCornerCard)
        #expect(!VoiceCapsuleSkin.bottomCapsule.isCornerCard)
    }

    @Test func ripplesSpreadWithTheVoice() {
        let quiet = VoiceCapsuleOrb.ripple(for: 0.05)
        #expect(quiet.inner.scale == 1 && quiet.inner.opacity == 0 && quiet.outer.opacity == 0)
        let loud = VoiceCapsuleOrb.ripple(for: 1)
        #expect(abs(loud.inner.scale - 1.32) < 0.001 && abs(loud.outer.scale - 1.6) < 0.001)
        #expect(abs(loud.inner.opacity - 0.9) < 0.001 && abs(loud.outer.opacity - 0.45) < 0.001)
    }

    @Test func modelPassesHoverRevealToTheSnapshot() {
        let model = OverlayViewModel()
        model.skin = .cornerCard(.trailing)
        model.presentation = .recordingLocked
        #expect(model.voiceCapsuleSnapshot?.controlsRevealed == false)
        model.cardControlsRevealed = true
        #expect(model.voiceCapsuleSnapshot?.controlsRevealed == true)
        // Revealing controls never expands the card.
        #expect(!model.voiceCapsuleExpanded)
    }

    @Test func phaseHelpersAndOrbResponse() {
        #expect(VoiceCapsulePhase.listening(handsFree: false).isListening)
        #expect(!VoiceCapsulePhase.processing.isListening)
        #expect(VoiceCapsulePhase.listening(handsFree: true).showsRecordingControls)
        #expect(!VoiceCapsulePhase.listening(handsFree: false).showsRecordingControls)
        #expect(VoiceCapsuleOrb.response(for: 0.05) == 0)
        #expect(abs(VoiceCapsuleOrb.response(for: 0.4) - 0.5) < 0.0001)
        #expect(VoiceCapsuleOrb.response(for: 1) == 1)
        #expect(VoiceCapsuleOrb.response(for: .nan) == 0)
        #expect(VoiceCapsuleSnapshot(phase: .failure).showsBody)
        #expect(!VoiceCapsuleSnapshot(phase: .processing).showsBody)
        #expect(VoiceCapsuleSnapshot(phase: .processing, expanded: true).showsBody)
    }

    @Test func modelMapsPresentationsToSkinState() {
        let model = OverlayViewModel()
        model.presentation = .recordingHold
        #expect(model.voiceCapsulePhase == .listening(handsFree: false))
        #expect(!model.drawsVoiceCapsuleSkin)
        model.skin = .cornerCard(.trailing)
        #expect(model.drawsVoiceCapsuleSkin)
        #expect(!model.voiceCapsuleExpanded)
        model.capsuleHovered = true
        #expect(model.voiceCapsuleExpanded)
        model.capsuleHovered = false
        model.presentation = .recordingLockedPreview
        model.recordingPreviewExpanded = true
        model.detailText = "Hello"
        #expect(model.voiceCapsulePhase == .listening(handsFree: true))
        #expect(model.voiceCapsuleSnapshot?.text == "Hello")
        #expect(model.voiceCapsuleSnapshot?.expanded == true)
        model.presentation = .processingPreview
        #expect(model.voiceCapsulePhase == .processing && model.voiceCapsuleExpanded)
        model.presentation = .processing
        #expect(!model.voiceCapsuleExpanded)
        model.presentation = .completed
        #expect(model.voiceCapsulePhase == .completed && model.presentation.isCapsule)
        model.presentation = .failure
        model.detailText = "Network timed out"
        #expect(model.voiceCapsuleSnapshot?.message == "Network timed out")
        #expect(model.voiceCapsuleSnapshot?.text == "")
        for presentation in [OverlayViewModel.Presentation.notice, .transcriptPreview, .personaPicker, .resultDialog] {
            model.presentation = presentation
            #expect(model.voiceCapsulePhase == nil && model.voiceCapsuleSnapshot == nil && !model.drawsVoiceCapsuleSkin)
        }
    }

    @Test func modelActionsForwardToTheController() {
        let model = OverlayViewModel()
        var calls: [String] = []
        model.onCancelRequested = { calls.append("cancel") }
        model.onConfirmRequested = { calls.append("confirm") }
        model.onDismissRequested = { calls.append("dismiss") }
        model.failureActions = [OverlayFailureAction(title: "Retry", isRetry: true, handler: { calls.append("retry") })]
        let actions = model.voiceCapsuleActions
        actions.cancel()
        actions.confirm()
        actions.dismiss()
        actions.failureAction(0)
        actions.failureAction(5)
        #expect(calls == ["cancel", "confirm", "dismiss", "retry"])
    }
}
