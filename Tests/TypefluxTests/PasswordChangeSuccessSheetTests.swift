import SwiftUI
import Testing
@testable import Typeflux

@Suite("Password change success sheet", .exclusiveUIState)
@MainActor
struct PasswordChangeSuccessSheetTests {
    @Test func successExplanationAndReloginActionRemainAccessible() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            var relogins = 0
            try await SettingsBehaviorTestSupport.withWindow(
                PasswordChangeSuccessSheet(onRelogin: { relogins += 1 }), width: 480, height: 240
            ) { _, host in
                #expect(SettingsBehaviorTestSupport.contains(L("auth.account.passwordChangeSuccessTitle"), in: host))
                #expect(SettingsBehaviorTestSupport.contains(L("auth.account.passwordChanged"), in: host))
                try SettingsBehaviorTestSupport.button(L("auth.account.relogin"), in: host).press()
                #expect(relogins == 1)
            }
        }
    }
}
