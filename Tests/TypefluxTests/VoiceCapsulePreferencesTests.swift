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
            // Hands-free recording is never called out; it reads like holding the shortcut.
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Listening · Notes")
            snapshot.phase = .processing
            #expect(VoiceCapsuleCopy.state(for: snapshot) == L("overlay.processing.thinking"))
            snapshot.statusText = "Polishing"
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Polishing · Notes")
            snapshot.targetAppName = nil
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == "Polishing")
            snapshot.phase = .failure
            snapshot.statusText = ""
            snapshot.targetAppName = "Notes"
            #expect(VoiceCapsuleCopy.subtitle(for: snapshot) == L("overlay.failure.title"))
            snapshot.statusText = "Timed out"
            #expect(VoiceCapsuleCopy.state(for: snapshot) == "Timed out")
        }
    }

    @Test func percentages() {
        withEnglish {
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
        #expect(VoiceCapsulePhase.listening(handsFree: false).cardControls == [.cancel, .confirm])
        #expect(VoiceCapsulePhase.listening(handsFree: true).cardControls == [.cancel, .confirm])
        #expect(VoiceCapsulePhase.processing.cardControls == [.cancel])
        #expect(VoiceCapsulePhase.failure.cardControls.isEmpty)
        #expect(VoiceCapsuleSkin.cornerCard(.leading).isCornerCard)
        #expect(!VoiceCapsuleSkin.bottomCapsule.isCornerCard)
        #expect(!VoiceCapsuleSkin.orbCapsule.isCornerCard)
    }

    @Test func failureFooterPlacesEveryAction() {
        withEnglish {
            func action(_ title: String, _ style: OverlayFailureAction.Style) -> OverlayFailureAction {
                OverlayFailureAction(title: title, isRetry: false, style: style, handler: {})
            }
            // Nothing to do: only the dismiss key.
            let plain = OverlayFailureFooterLayout(actions: [])
            #expect(plain.linkIndex == nil && plain.pillIndices.isEmpty)
            #expect(plain.hint == "Esc to close")
            // One action: Return runs it, so the hint names it.
            let retry = OverlayFailureFooterLayout(actions: [action("Retry", .primary)])
            #expect(retry.pillIndices == [0] && retry.hint == "⏎ Retry · Esc to close")
            // Two pills take the row; the primary one goes last.
            let login = OverlayFailureFooterLayout(actions: [action("Log in", .primary), action("Configure", .secondary)])
            #expect(login.pillIndices == [1, 0] && login.hint == nil && login.linkIndex == nil)
            // A text action becomes the link on the left.
            let billing = OverlayFailureFooterLayout(actions: [action("Upgrade", .primary), action("Switch model", .text)])
            #expect(billing.linkIndex == 1 && billing.pillIndices == [0] && billing.hint == nil)
            // Only the first text action is a link; another one falls back to a pill.
            let twoLinks = OverlayFailureFooterLayout(actions: [action("A", .text), action("B", .text)])
            #expect(twoLinks.linkIndex == 0 && twoLinks.pillIndices == [1])
        }
    }

    @Test func failureCountdownPausesAndResumes() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var countdown = OverlayFailureCountdown(total: 6, startedAt: start)
        #expect(!countdown.isPaused && countdown.fraction(at: start) == 1)
        #expect(abs(countdown.remaining(at: start.addingTimeInterval(1.5)) - 4.5) < 0.001)
        countdown = countdown.paused(at: start.addingTimeInterval(3))
        #expect(countdown.isPaused && abs(countdown.remaining - 3) < 0.001)
        // Time does not run while paused, and pausing twice changes nothing.
        #expect(abs(countdown.fraction(at: start.addingTimeInterval(60)) - 0.5) < 0.001)
        #expect(countdown.paused(at: start.addingTimeInterval(60)) == countdown)
        countdown = countdown.resumed(at: start.addingTimeInterval(10))
        #expect(countdown.resumed(at: start.addingTimeInterval(20)) == countdown)
        #expect(abs(countdown.remaining(at: start.addingTimeInterval(11)) - 2) < 0.001)
        #expect(countdown.remaining(at: start.addingTimeInterval(99)) == 0)
        #expect(OverlayFailureCountdown(total: 0, startedAt: start).fraction(at: start) == 0)
    }

    @Test @MainActor func failureCardRendersEveryTone() throws {
        let actions = [
            OverlayFailureAction(title: "Upgrade", isRetry: false, trailingSystemImage: "arrow.up.right", handler: {}),
            OverlayFailureAction(title: "Configure", isRetry: false, style: .secondary, handler: {}),
            OverlayFailureAction(title: "Switch model", isRetry: false, style: .text, handler: {})
        ]
        let tones: [OverlayFailureTone] = [.error, .timeout, .billing]
        for tone in tones {
            for (actionCount, countdown) in [(0, OverlayFailureCountdown(total: 6, startedAt: Date())), (1, nil), (3, nil)] {
                let card = OverlayFailureCard(
                    title: "Processing failed", message: String(repeating: "The network timed out. ", count: 3),
                    tone: tone, actions: Array(actions.prefix(actionCount)), countdown: countdown,
                    onAction: { _ in }, onDismiss: {}
                )
                let view = NSHostingView(rootView: card)
                #expect(abs(view.fittingSize.width - OverlayFailureCard.width) < 0.5)
                #expect(view.fittingSize.height > 90 && view.fittingSize.height < 200)
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
        }
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
        model.presentation = .failure
        #expect(!model.presentation.isCapsule)
        model.failureCountdown = OverlayFailureCountdown(total: 6, startedAt: Date())
        #expect(model.voiceCapsuleSnapshot?.failureCountdown != nil)
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
