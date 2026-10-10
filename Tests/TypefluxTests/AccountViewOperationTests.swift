import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite("Account page operations", .serialized, .exclusiveUIState)
struct AccountViewOperationTests {
    @Test func passwordValidationAndDismissalStayOnTheAccountPage() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try BillingOperationFixture(.accountPlans, defaults: settings.defaults)
            do {
                await fixture.prepare()
                try await SettingsBehaviorTestSupport.withWindow(fixture.view(), height: 1000) { window, host in
                    try SettingsBehaviorTestSupport.button(L("auth.account.changePassword"), in: host).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet?.contentView != nil }
                    let sheet = try #require(window.attachedSheet)
                    let content = try #require(sheet.contentView)
                    try await SettingsBehaviorTestSupport.wait { fields(in: content).count == 3 }
                    let inputs = fields(in: content)
                    let current = try #require(inputs.first {
                        $0.placeholderString == L("auth.account.currentPassword")
                    })
                    let new = try #require(inputs.first { $0.placeholderString == L("auth.account.newPassword") })
                    let confirm = try #require(inputs.first {
                        $0.placeholderString == L("auth.account.confirmNewPassword")
                    })
                    try await validatePasswordForm(current: current, new: new, confirm: confirm,
                                                   sheet: sheet, auth: fixture.auth)
                    #expect(fixture.auth.userProfile?.id == "a1")
                    #expect(fixture.links.isEmpty)
                    try SettingsBehaviorTestSupport.button(L("common.cancel"), in: content).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                    #expect(SettingsBehaviorTestSupport.contains("Billing Fixture", in: host))
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }

    @Test func logoutRequiresConfirmationAndCallsTheOwnerOnce() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try BillingOperationFixture(.accountPlans, defaults: settings.defaults)
            var logoutCount = 0
            do {
                await fixture.prepare()
                try await SettingsBehaviorTestSupport.withWindow(
                    AccountView(authState: fixture.auth, onLogout: { logoutCount += 1 }), height: 1000
                ) { window, host in
                    try SettingsBehaviorTestSupport.button(L("auth.account.logout"), in: host).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                    var sheet = try #require(window.attachedSheet)
                    try SettingsBehaviorTestSupport.button(L("common.cancel"), in: sheet).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                    #expect(fixture.auth.isLoggedIn)
                    #expect(logoutCount == 0)
                    try SettingsBehaviorTestSupport.button(L("auth.account.logout"), in: host).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                    sheet = try #require(window.attachedSheet)
                    try SettingsBehaviorTestSupport.button(L("auth.account.logout"), in: sheet).press()
                    try await SettingsBehaviorTestSupport.wait {
                        !fixture.auth.isLoggedIn && window.attachedSheet == nil
                    }
                    #expect(logoutCount == 1)
                    #expect(fixture.auth.userProfile == nil)
                    #expect(fixture.auth.accessToken == nil)
                    try await SettingsBehaviorTestSupport.wait {
                        SettingsBehaviorTestSupport.contains(L("auth.account.signedOutTitle"), in: host)
                    }
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }

    @Test func loadingAccountDoesNotOfferActions() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try BillingOperationFixture(.accountPlans, defaults: settings.defaults)
            fixture.auth.isLoading = true
            do {
                try await SettingsBehaviorTestSupport.withWindow(fixture.view()) { _, host in
                    #expect(!fixture.hasButton(in: host))
                    #expect(!SettingsBehaviorTestSupport.contains(L("auth.account.signedOutTitle"), in: host))
                    fixture.auth.isLoading = false
                    try await SettingsBehaviorTestSupport.wait {
                        SettingsBehaviorTestSupport.contains(L("auth.account.signedOutTitle"), in: host)
                    }
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }

    private func validatePasswordForm(current: NSTextField, new: NSTextField, confirm: NSTextField,
                                      sheet: NSWindow, auth: AuthState) async throws {
        let content = try #require(sheet.contentView)
        let submit = try SettingsBehaviorTestSupport.button(L("auth.account.changePassword"), in: content)
        try submit.press()
        try await expectError("auth.error.currentPasswordRequired", in: content)
        try fill(current, with: "FixtureOld1", in: sheet)
        try submit.press()
        try await expectError("auth.error.passwordRequired", in: content)
        try fill(new, with: "New1", in: sheet)
        try fill(confirm, with: "Other1", in: sheet)
        try submit.press()
        try await expectError("auth.error.passwordMismatch", in: content)
        try fill(confirm, with: "New1", in: sheet)
        try submit.press()
        try await expectError("auth.error.passwordTooShort", in: content)
        try fill(new, with: "weakpassword", in: sheet)
        try fill(confirm, with: "weakpassword", in: sheet)
        try submit.press()
        try await expectError("auth.error.passwordTooWeak", in: content)
        // A locally lost token must be rejected before any password request.
        auth.inMemorySessionToken = nil
        auth.cachedStoredToken = nil
        try fill(new, with: "ValidFixture1", in: sheet)
        try fill(confirm, with: "ValidFixture1", in: sheet)
        try submit.press()
        try await expectError("auth.error.unauthorized", in: content)
    }

    private func expectError(_ key: String, in content: NSView) async throws {
        try await SettingsBehaviorTestSupport.wait { SettingsBehaviorTestSupport.contains(L(key), in: content) }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    private func fill(_ field: NSTextField, with value: String, in window: NSWindow) throws {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        window.makeFirstResponder(nil)
        #expect(field.stringValue == value)
    }
}
