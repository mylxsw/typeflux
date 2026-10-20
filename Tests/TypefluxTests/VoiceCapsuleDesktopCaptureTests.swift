import AppKit
import Testing
@testable import Typeflux

/// Opt-in: shows each top-skin state on the real desktop and saves a full-screen capture.
/// Run with `TYPEFLUX_CAPSULE_SCREENSHOT_DIR=/path` on a machine with screen recording access.
@Suite(.serialized, .exclusiveUIState, .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_CAPSULE_SCREENSHOT_DIR"] != nil))
struct VoiceCapsuleDesktopCaptureTests {
    private static let transcript = "明天下午三点跟设计团队过一下语音胶囊的新方案，然后把会议纪要发给大家"

    @Test(arguments: VoiceCapsuleStyle.allCases) @MainActor
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
        if style == .orbCapsule {
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
        if style == .orbCapsule || style == .cornerCard {
            controller.simulateCapsuleHoverForTesting(true)
            try await shoot("3b-handsfree-hover")
            controller.simulateCapsuleHoverForTesting(false)
            try await Task.sleep(for: .seconds(OverlayController.cardControlsHideDelay + 0.1))
        }
        controller.showProcessing()
        controller.transitionToLLMPhase()
        try await shoot("4-processing")
        if style == .orbCapsule || style == .cornerCard {
            controller.simulateCapsuleHoverForTesting(true)
            try await shoot("4b-processing-hover")
            controller.simulateCapsuleHoverForTesting(false)
        }
        controller.showRetryableFailure(message: "网络连接超时，录音已保存。你可以重试，或稍后在历史记录中找回原文。")
        try await shoot("5-failure-retry")
        controller.showTimeoutFailure(timeoutSeconds: 30)
        try await shoot("6-failure-timeout")
        controller.showFailure(message: "麦克风启动失败：没有找到可用的输入设备。请在「系统设置 › 隐私与安全性」中检查麦克风权限。")
        try await shoot("7-failure-plain")
        controller.showFailureWithActions(
            title: "免费云端额度已用完",
            message: "本月的免费云端额度已经用完。升级套餐可以继续使用云端转写与润色，也可以切换到其他模型。",
            tone: .billing,
            actions: [
                OverlayFailureAction(title: "升级套餐", isRetry: false, trailingSystemImage: "arrow.up.right", handler: {}),
                OverlayFailureAction(title: "切换其他模型", isRetry: false, style: .text, handler: {})
            ]
        )
        try await shoot("8-failure-billing")
    }
}
