import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Drives the real overlay window through every state of the top skins.
/// Set `TYPEFLUX_OVERLAY_CAPTURE_DIR` to keep the rendered frames.
@Suite(.serialized, .exclusiveUIState)
struct VoiceCapsuleOverlayTests {
    private struct Fixture {
        let controller: OverlayController
        let defaults: UserDefaults
        let suite: String
        let screen: VoiceCapsuleScreenGeometry

        @MainActor
        init(style: VoiceCapsuleStyle, configure: (inout VoiceCapsulePreferences) -> Void = { _ in }) throws {
            suite = "VoiceCapsuleOverlayTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            let store = SettingsStore(defaults: defaults)
            var preferences = VoiceCapsulePreferences()
            preferences.style = style
            preferences.screen = .main
            configure(&preferences)
            store.voiceCapsule = preferences
            controller = OverlayController(appState: AppStateStore(), settingsStore: store)
            controller.motionScale = 0.01
            screen = try #require(OverlayController.placementScreenGeometry(for: .main))
        }

        @MainActor
        func clean() {
            controller.dismissImmediately()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test @MainActor
    func cornerCardGrowsBelowTheMenuBarAndLeavesWithoutAConfirmation() async throws {
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let fixture = try Fixture(style: .cornerCard)
        defer { fixture.clean() }
        let controller = fixture.controller

        controller.show()
        let window = try #require(controller.presentedWindow)
        try await settle()
        #expect(controller.voiceCapsuleSkinForTesting == .cornerCard(.trailing))
        let compact = window.frame
        #expect(compact.size == CGSize(width: 420, height: 100))
        #expect(compact.maxX - VoiceCapsuleLayout.cardGutter.right == fixture.screen.visibleFrame.maxX - 14)
        #expect(compact.maxY - VoiceCapsuleLayout.cardGutter.top == fixture.screen.visibleFrame.maxY - 10)
        #expect(!window.ignoresMouseEvents)
        try capture(window, name: "corner-listening")

        controller.updateLevel(0.6)
        controller.showLockedRecording()
        let transcript = "明天下午三点跟设计团队过一下语音胶囊的新方案，然后把会议纪要发给大家"
        controller.updateRecordingPreviewText(transcript)
        try await settle()
        let lines = VoiceCapsuleLayout.transcriptLines(for: .cornerCard(.trailing), text: transcript)
        #expect(lines == 2)
        #expect(window.frame.height == VoiceCapsuleLayout.cardExpandedHeight(lines: lines) + 36)
        #expect(window.frame.maxY == compact.maxY)
        try capture(window, name: "corner-handsfree-transcript")

        controller.showProcessing()
        controller.transitionToLLMPhase()
        try await settle()
        #expect(window.frame.size == compact.size)
        // The corner card still accepts the pointer while processing so hover can offer cancel.
        #expect(!window.ignoresMouseEvents)
        try capture(window, name: "corner-processing")

        // Delivered text needs no confirmation: the card simply leaves.
        controller.dismissProcessingImmediatelyIfVisible()
        try await settle()
        #expect(!window.isVisible)
    }

    @Test @MainActor
    func cornerCardShowsFailuresInsideTheCard() async throws {
        let fixture = try Fixture(style: .cornerCard) { $0.cornerEdge = .leading }
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.showLockedRecording()
        let window = try #require(controller.presentedWindow)
        controller.showRetryableFailure(message: "The network timed out. Your recording was saved.")
        try await settle()
        #expect(window.frame.minX + VoiceCapsuleLayout.cardGutter.left == fixture.screen.visibleFrame.minX + 14)
        #expect(window.frame.width == 420)
        #expect(window.frame.height > 140 && window.frame.height < 300)
        #expect(window.contentView?.layer?.cornerRadius == 0)
        #expect(!window.ignoresMouseEvents)
        try capture(window, name: "corner-failure")
    }

    @Test @MainActor
    func notchIslandHangsFromTheTopEdge() async throws {
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let fixture = try Fixture(style: .notchIsland)
        defer { fixture.clean() }
        let controller = fixture.controller
        let skin = VoiceCapsuleLayout.skin(for: {
            var preferences = VoiceCapsulePreferences()
            preferences.style = .notchIsland
            return preferences
        }(), on: fixture.screen)
        guard case let .notchIsland(notch) = skin else {
            Issue.record("Expected an island, got \(skin)")
            return
        }

        controller.show()
        let window = try #require(controller.presentedWindow)
        try await settle()
        #expect(controller.voiceCapsuleSkinForTesting == skin)
        #expect(window.frame.maxY == fixture.screen.frame.maxY)
        #expect(window.frame.midX == notch.midX)
        #expect(window.frame.height == notch.height)
        #expect(window.frame.width == notch.width + VoiceCapsuleLayout.earWidth * 2 + VoiceCapsuleLayout.islandFillet * 2)
        try capture(window, name: "notch-listening")

        controller.updateLevel(0.6)
        controller.updateRecordingPreviewText("明天下午三点跟设计团队过一下语音胶囊的新方案")
        try await settle()
        #expect(window.frame.height == notch.height + VoiceCapsuleLayout.islandBodyHeight(lines: 1))
        #expect(window.frame.maxY == fixture.screen.frame.maxY)
        try capture(window, name: "notch-transcript")

        controller.showLockedRecording()
        controller.updateRecordingPreviewText("明天下午三点跟设计团队过一下语音胶囊的新方案，然后把会议纪要发给大家")
        try await settle()
        try capture(window, name: "notch-handsfree")

        controller.showProcessing()
        try await settle()
        #expect(window.frame.height == notch.height)
        try capture(window, name: "notch-processing")

        controller.showFailure(message: "网络连接超时，录音已保存。")
        try await settle()
        #expect(window.frame.maxY == fixture.screen.frame.maxY)
        #expect(window.frame.height > notch.height + 40)
        try capture(window, name: "notch-failure")
    }

    @Test @MainActor
    func hoveringTheCornerCardRevealsControlsWithoutResizing() async throws {
        let fixture = try Fixture(style: .cornerCard)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.showLockedRecording()
        controller.updateRecordingPreviewText("A short transcript")
        let window = try #require(controller.presentedWindow)
        try await settle()
        let frame = window.frame
        #expect(!controller.cardControlsRevealedForTesting)

        controller.simulateCapsuleHoverForTesting(true)
        #expect(controller.cardControlsRevealedForTesting)
        try await settle()
        #expect(window.frame == frame)
        try capture(window, name: "corner-handsfree-hover")

        // A brief exit and return keeps the controls up.
        controller.simulateCapsuleHoverForTesting(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.cardControlsRevealedForTesting)
        controller.simulateCapsuleHoverForTesting(true)
        controller.simulateCapsuleHoverForTesting(false)
        try await Task.sleep(for: .seconds(OverlayController.cardControlsHideDelay + 0.15))
        #expect(!controller.cardControlsRevealedForTesting)
        #expect(window.frame == frame)

        // Hiding the overlay clears the hover state for the next session.
        controller.simulateCapsuleHoverForTesting(true)
        controller.dismissImmediately()
        #expect(!controller.cardControlsRevealedForTesting)
    }

    @Test @MainActor
    func hoverExpandsTheIslandOnlyWhenAllowed() async throws {
        for allowsHover in [true, false] {
            let fixture = try Fixture(style: .notchIsland) { $0.notchHoverExpands = allowsHover }
            defer { fixture.clean() }
            let controller = fixture.controller
            controller.show()
            let window = try #require(controller.presentedWindow)
            try await settle()
            let compactHeight = window.frame.height
            controller.simulateCapsuleHoverForTesting(true)
            try await Task.sleep(for: .milliseconds(450))
            #expect((window.frame.height > compactHeight) == allowsHover)
            controller.simulateCapsuleHoverForTesting(false)
            try await Task.sleep(for: .milliseconds(700))
            #expect(window.frame.height == compactHeight)
        }
    }

    @Test @MainActor
    func livePreviewCanBeTurnedOff() async throws {
        let fixture = try Fixture(style: .cornerCard) { $0.showsLivePreview = false }
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.show()
        let window = try #require(controller.presentedWindow)
        try await settle()
        let compact = window.frame
        controller.updateRecordingPreviewText("Text that would otherwise expand the card")
        try await settle()
        #expect(window.frame == compact)
        #expect(controller.recordingPresentationForTesting == .recordingHold)
    }

    @Test @MainActor
    func orbCapsuleRevealsControlsOnHover() async throws {
        let fixture = try Fixture(style: .orbCapsule)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.show()
        controller.updateLevel(0.6)
        let window = try #require(controller.presentedWindow)
        try await settle()
        #expect(controller.voiceCapsuleSkinForTesting == .orbCapsule)
        // The original envelope, accepting the pointer so hover can reveal the controls.
        #expect(window.frame.size == CGSize(width: 146, height: 112))
        #expect(!window.ignoresMouseEvents)
        try capture(window, name: "orb-hold")

        controller.simulateCapsuleHoverForTesting(true)
        #expect(controller.cardControlsRevealedForTesting)
        try await settle()
        #expect(window.frame.size == CGSize(width: 146, height: 112))
        try capture(window, name: "orb-hold-hover")
        controller.simulateCapsuleHoverForTesting(false)
        try await Task.sleep(for: .seconds(OverlayController.cardControlsHideDelay + 0.15))
        #expect(!controller.cardControlsRevealedForTesting)

        controller.updateRecordingPreviewText("明天下午三点跟设计团队过一下语音胶囊的新方案")
        try await settle()
        try capture(window, name: "orb-transcript")

        controller.showProcessing()
        controller.transitionToLLMPhase()
        try await settle()
        #expect(!window.ignoresMouseEvents)
        try capture(window, name: "orb-processing")

        controller.dismissProcessingImmediatelyIfVisible()
        try await settle()
        #expect(!window.isVisible)
    }

    @Test @MainActor
    func classicCapsuleKeepsItsOriginalBehavior() async throws {
        let fixture = try Fixture(style: .bottomCapsule)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.show()
        let window = try #require(controller.presentedWindow)
        try await settle()
        #expect(controller.voiceCapsuleSkinForTesting == .bottomCapsule)
        #expect(window.frame.size == CGSize(width: 146, height: 112))
        // Holding the shortcut leaves the pointer alone, and hovering reveals nothing.
        #expect(window.ignoresMouseEvents)
        controller.simulateCapsuleHoverForTesting(true)
        #expect(!controller.cardControlsRevealedForTesting)

        // Hands-free recording shows its buttons and takes clicks, as before.
        controller.showLockedRecording()
        try await settle()
        #expect(!window.ignoresMouseEvents)

        controller.showProcessing()
        try await settle()
        #expect(window.ignoresMouseEvents)
        controller.dismissProcessingImmediatelyIfVisible()
        try await settle()
        #expect(!window.isVisible)
    }

    @Test(arguments: [VoiceCapsuleStyle.bottomCapsule, .orbCapsule]) @MainActor
    func failureCardRisesFromTheCapsule(style: VoiceCapsuleStyle) async throws {
        let fixture = try Fixture(style: style)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.show()
        let window = try #require(controller.presentedWindow)
        try await settle()
        let capsule = window.frame
        controller.showRetryableFailure(message: "The network timed out. Your recording was saved.")
        // The window morphs from the capsule's envelope; wait until it stops moving.
        var previous = NSRect.zero
        for _ in 0 ..< 20 where window.frame != previous {
            previous = window.frame
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(window.frame.width == OverlayFailureCard.width + 56)
        #expect(window.frame.minY == capsule.minY)
        #expect(abs(window.frame.midX - capsule.midX) <= 0.5)
        // The card draws its own glass; the window has no chrome of its own.
        #expect(window.contentView?.layer?.cornerRadius == 0)
        #expect(!window.ignoresMouseEvents)
        // A failure with an action waits for the user.
        #expect(controller.failureCountdownForTesting == nil)
        try capture(window, name: "\(style.rawValue)-failure")
    }

    @Test @MainActor
    func failuresWithoutActionsLeaveOnTheirOwnUnlessHovered() async throws {
        let fixture = try Fixture(style: .bottomCapsule)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.failureAutoDismissDelay = 0.4
        controller.showFailure(message: "No microphone was found.")
        let window = try #require(controller.presentedWindow)
        try await settle()
        let countdown = try #require(controller.failureCountdownForTesting)
        #expect(countdown.total == 0.4 && !countdown.isPaused)

        // The pointer over the card holds it in place past the deadline.
        controller.simulateCapsuleHoverForTesting(true)
        #expect(controller.failureCountdownForTesting?.isPaused == true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(window.isVisible)

        // Leaving resumes the rest of the countdown.
        controller.simulateCapsuleHoverForTesting(false)
        #expect(controller.failureCountdownForTesting?.isPaused == false)
        try await Task.sleep(for: .milliseconds(700))
        #expect(!window.isVisible)
        #expect(controller.failureCountdownForTesting == nil)

        // A failure that replaces the timed one with an action stays.
        controller.showFailure(message: "No microphone was found.")
        controller.showRetryableFailure(message: "The network timed out.")
        try await Task.sleep(for: .milliseconds(700))
        #expect(window.isVisible)
        #expect(controller.failureCountdownForTesting == nil)
    }

    @Test @MainActor
    func timeoutFailuresUseTheirOwnTone() async throws {
        let fixture = try Fixture(style: .orbCapsule)
        defer { fixture.clean() }
        fixture.controller.showTimeoutFailure(timeoutSeconds: 30)
        let window = try #require(fixture.controller.presentedWindow)
        try await settle()
        #expect(window.isVisible)
        try capture(window, name: "orb-timeout")
    }

    @Test @MainActor
    func changingTheStyleRestylesAVisibleCapsule() async throws {
        let fixture = try Fixture(style: .bottomCapsule)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.show()
        try await settle()
        var preferences = SettingsStore(defaults: fixture.defaults).voiceCapsule
        preferences.style = .cornerCard
        SettingsStore(defaults: fixture.defaults).voiceCapsule = preferences
        try await settle()
        #expect(controller.voiceCapsuleSkinForTesting == .cornerCard(.trailing))
    }

    @Test @MainActor
    func skinsRenderEveryPhase() throws {
        let notch = VoiceCapsuleNotchGeometry(midX: 0, width: 190, height: 32, isHardware: true)
        let started = Date().addingTimeInterval(-7)
        let phases: [VoiceCapsulePhase] = [.listening(handsFree: false), .listening(handsFree: true), .processing,
                                            .failure]
        for phase in phases {
            for (expanded, revealed) in [(false, false), (true, false), (false, true), (true, true)] {
                let snapshot = VoiceCapsuleSnapshot(
                    phase: phase, text: expanded ? "Live transcript" : "", level: 0.5, progress: 0.62,
                    statusText: "", message: "Timed out", targetAppName: "Notes", recordingStartedAt: started,
                    expanded: expanded, controlsRevealed: revealed,
                    failureActions: revealed ? [] : [OverlayFailureAction(title: "Retry", isRetry: true, handler: {})],
                    failureCountdown: revealed ? OverlayFailureCountdown(total: 6, startedAt: started) : nil
                )
                let card = NSHostingView(rootView: CornerCardCapsule(snapshot: snapshot, actions: VoiceCapsuleActions()))
                let island = NSHostingView(rootView: NotchIslandCapsule(snapshot: snapshot, notch: notch,
                                                                        actions: VoiceCapsuleActions()))
                #expect(abs(card.fittingSize.width - VoiceCapsuleLayout.cardWidth) < 0.5)
                #expect(abs(island.fittingSize.width - ((snapshot.showsBody ? 560 : 190 + 192) + 16)) < 0.5)
                for view in [card, island] as [NSView] {
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
            }
        }
    }

    @Test @MainActor
    func settingsSectionRendersEveryStyle() {
        for style in VoiceCapsuleStyle.allCases {
            var preferences = VoiceCapsulePreferences()
            preferences.style = style
            let section = VoiceCapsuleSettingsSection(preferences: .constant(preferences))
            let host = NSHostingView(rootView: section.frame(width: 760))
            #expect(host.fittingSize.height > 200)
            let preview = NSHostingView(rootView: VoiceCapsuleStylePreview(style: style))
            #expect(preview.fittingSize.height == 100)
            #expect(preview.fittingSize.width >= 112 && preview.fittingSize.width <= 160)
        }
        // The original capsule stays next to the three new styles.
        #expect(VoiceCapsuleStyle.allCases == [.bottomCapsule, .orbCapsule, .cornerCard, .notchIsland])
    }

    // MARK: - Helpers

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor
    private func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_OVERLAY_CAPTURE_DIR"] else { return }
        let view = try #require(window.contentView)
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("voice-capsule-\(name).png"))
    }
}
