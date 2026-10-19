import AppKit
import Testing
@testable import Typeflux

/// Opt-in: records the notch island growing a caption and closing again, for frame-by-frame review.
/// Run with `TYPEFLUX_NOTCH_MOTION_DIR=/path` on a machine with screen recording access.
@Suite(.serialized, .exclusiveUIState,
       .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_NOTCH_MOTION_DIR"] != nil))
struct NotchIslandMotionRecordingTests {
    @Test @MainActor
    func recordCaptionOpeningAndClosing() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TYPEFLUX_NOTCH_MOTION_DIR"])
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let suite = "NotchIslandMotionRecordingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var preferences = VoiceCapsulePreferences()
        preferences.style = .notchIsland
        preferences.screen = .main
        store.voiceCapsule = preferences
        let controller = OverlayController(appState: AppStateStore(), settingsStore: store)
        defer { controller.dismissImmediately() }
        let screen = try #require(NSScreen.main)

        let recording = Process()
        recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let region = "\(Int(screen.frame.midX) - 400),0,800,240"
        recording.arguments = ["-x", "-v", "-V", "9", "-R", region,
                               URL(fileURLWithPath: directory).appendingPathComponent("notch.mov").path]
        try recording.run()
        try await Task.sleep(for: .milliseconds(1200))

        let transcript = "明天下午三点跟设计团队过一下语音胶囊的新方案，然后把会议纪要整理好发给大家，顺便约下周的评审时间"
        controller.show()
        controller.updateLevel(0.6)
        try await Task.sleep(for: .milliseconds(1200))
        controller.updateRecordingPreviewText(String(transcript.prefix(12)))
        try await Task.sleep(for: .milliseconds(1000))
        controller.updateRecordingPreviewText(String(transcript.prefix(34)))
        try await Task.sleep(for: .milliseconds(1000))
        controller.updateRecordingPreviewText(transcript)
        try await Task.sleep(for: .milliseconds(1000))
        controller.showProcessing()
        try await Task.sleep(for: .milliseconds(1200))
        controller.dismiss(after: 0)
        // Keep the main run loop free so the dismissal still animates while the recording ends.
        while recording.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(recording.terminationStatus == 0)
    }
}
