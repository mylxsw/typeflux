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
    func cornerCardGrowsBelowTheMenuBarAndConfirmsDelivery() async throws {
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
        #expect(window.ignoresMouseEvents)
        try capture(window, name: "corner-processing")

        controller.dismissProcessingImmediatelyIfVisible()
        controller.showDeliveryConfirmation(characterCount: 35)
        try await settle()
        #expect(controller.recordingPresentationForTesting == .completed)
        #expect(window.isVisible)
        #expect(controller.isCapsulePresentedForTesting)
        try capture(window, name: "corner-completed")
        try await Task.sleep(for: .seconds(OverlayController.completionDisplayDuration + 0.4))
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

        controller.dismissImmediately()
        controller.showDeliveryConfirmation(characterCount: 35)
        try await settle()
        #expect(controller.recordingPresentationForTesting == .completed)
        #expect(controller.isCapsulePresentedForTesting)
        try capture(window, name: "notch-completed")
        // A new recording during the confirmation keeps the overlay.
        controller.show()
        try await Task.sleep(for: .seconds(OverlayController.completionDisplayDuration + 0.3))
        #expect(window.isVisible && controller.recordingPresentationForTesting == .recordingHold)
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
    func bottomCapsuleKeepsItsQuietExit() async throws {
        let fixture = try Fixture(style: .bottomCapsule)
        defer { fixture.clean() }
        let controller = fixture.controller
        controller.showDeliveryConfirmation(characterCount: 12)
        #expect(controller.presentedWindow?.isVisible != true)
        controller.show()
        try await settle()
        #expect(controller.voiceCapsuleSkinForTesting == .bottomCapsule)
        // A notch island that falls back to the bottom capsule behaves the same way.
        let fallback = try Fixture(style: .notchIsland) { $0.notchFallback = .bottomCapsule }
        defer { fallback.clean() }
        if fallback.screen.hardwareNotch == nil {
            fallback.controller.showDeliveryConfirmation(characterCount: 12)
            #expect(fallback.controller.presentedWindow?.isVisible != true)
        }
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
                                            .completed, .failure]
        for phase in phases {
            for expanded in [false, true] {
                let snapshot = VoiceCapsuleSnapshot(
                    phase: phase, text: expanded ? "Live transcript" : "", level: 0.5, progress: 0.62,
                    statusText: "", message: "Timed out", targetAppName: "Notes", recordingStartedAt: started,
                    completedCharacterCount: 3, expanded: expanded,
                    failureActions: [OverlayFailureAction(title: "Retry", isRetry: true, handler: {})]
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
            for badge in [false, true] {
                var preferences = VoiceCapsulePreferences()
                preferences.style = style
                let section = VoiceCapsuleSettingsSection(preferences: .constant(preferences), hasNotchedDisplay: badge)
                let host = NSHostingView(rootView: section.frame(width: 760))
                #expect(host.fittingSize.height > 200)
                let preview = NSHostingView(rootView: VoiceCapsuleStylePreview(style: style, showsBadge: badge))
                #expect(preview.fittingSize == CGSize(width: 160, height: 100))
            }
        }
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
