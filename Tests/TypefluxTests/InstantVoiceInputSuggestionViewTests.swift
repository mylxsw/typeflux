import AppKit
import Testing
@testable import Typeflux

@Suite("Instant voice input suggestion", .exclusiveUIState)
@MainActor
struct InstantVoiceInputSuggestionViewTests {
    @Test(arguments: [false, true])
    func `both suggestion actions are available`(enable: Bool) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            var enabled = false
            var cancelled = false
            let view = InstantVoiceInputSuggestionView(
                onEnable: { enabled = true }, onCancel: { cancelled = true }
            )
            try await SettingsBehaviorTestSupport.withWindow(view, width: 440, height: 210) { _, host in
                #expect(SettingsBehaviorTestSupport.contains(
                    L("settings.instantVoiceInput.suggestion.title"), in: host
                ))
                let title = enable ? L("settings.instantVoiceInput.suggestion.enable") : L("common.cancel")
                try SettingsBehaviorTestSupport.button(title, in: host).press()
                #expect(enabled == enable)
                #expect(cancelled == !enable)
            }
        }
    }
}
