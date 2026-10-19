import AppKit
import Testing
@testable import Typeflux

/// Opt-in: shows each top-skin state on the real desktop and saves a full-screen capture.
/// Run with `TYPEFLUX_CAPSULE_SCREENSHOT_DIR=/path` on a machine with screen recording access.
@Suite(.serialized, .exclusiveUIState,
       .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_CAPSULE_SCREENSHOT_DIR"] != nil))
struct VoiceCapsuleDesktopCaptureTests {
    private static let transcript = "明天下午三点跟设计团队过一下语音胶囊的新方案，然后把会议纪要发给大家"

    @Test(arguments: [VoiceCapsuleStyle.cornerCard, .notchIsland, .bottomCapsule]) @MainActor
    func captureEveryState(style: VoiceCapsuleStyle) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TYPEFLUX_CAPSULE_SCREENSHOT_DIR"])
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        let suite = "VoiceCapsuleDesktopCaptureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var preferences = VoiceCapsulePreferences()
        preferences.style = style
        preferences.screen = .main
        store.voiceCapsule = preferences
        let controller = OverlayController(appState: AppStateStore(), settingsStore: store)
        defer { controller.dismissImmediately() }

        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(900))
            let path = URL(fileURLWithPath: directory).appendingPathComponent("\(style.rawValue)-\(name).png").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-m", path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        controller.show()
        controller.updateLevel(0.55)
        try await shoot("1-listening")
        if style == .bottomCapsule {
            controller.simulateCapsuleHoverForTesting(true)
            try await shoot("1b-listening-hover")
            controller.simulateCapsuleHoverForTesting(false)
            try await Task.sleep(for: .seconds(OverlayController.cardControlsHideDelay + 0.1))
        }
        controller.updateRecordingPreviewText(String(Self.transcript.prefix(22)))
        controller.updateLevel(0.7)
        try await shoot("2-transcript")
        controller.showLockedRecording()
        controller.updateRecordingPreviewText(Self.transcript)
        try await shoot("3-handsfree")
        if style != .notchIsland {
            controller.simulateCapsuleHoverForTesting(true)
            try await shoot("3b-handsfree-hover")
            controller.simulateCapsuleHoverForTesting(false)
            try await Task.sleep(for: .seconds(OverlayController.cardControlsHideDelay + 0.1))
        }
        controller.showProcessing()
        controller.transitionToLLMPhase()
        try await shoot("4-processing")
        if style != .notchIsland {
            controller.simulateCapsuleHoverForTesting(true)
            try await shoot("4b-processing-hover")
            controller.simulateCapsuleHoverForTesting(false)
        }
        controller.dismissProcessingImmediatelyIfVisible()
        controller.showDeliveryConfirmation(characterCount: 35)
        try await Task.sleep(for: .milliseconds(500))
        let completed = URL(fileURLWithPath: directory).appendingPathComponent("\(style.rawValue)-5-completed.png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", completed]
        try process.run()
        process.waitUntilExit()
        try await Task.sleep(for: .seconds(1.5))
        controller.showRetryableFailure(message: "网络连接超时，录音已保存。你可以重试，或稍后在历史记录中找回原文。")
        try await shoot("6-failure")
    }
}
