import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Grouped settings snapshots", .exclusiveUIState)
@MainActor
struct SettingsPagesSnapshotTests {
    @Test func pageMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_PAGES_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                                        initialSection: .settings,
                                        modelLibrary: AskModelLibrary(
                                            defaults: settings.defaults, automaticallyLoadsCatalog: false))
            model.setLiquidGlassIntensity(0.7)
            model.setMouseVoiceInputEnabled(true)
            model.refreshPermissionRows()
            for style in InterfaceStyle.allCases {
                model.setInterfaceStyle(style)
                for dark in [false, true] {
                    let suffix = "\(style.rawValue)-\(dark ? "dark" : "light").png"
                    try await TypefluxUISnapshot.render(GeneralSettingsView(viewModel: model, onManageMemory: {}),
                        size: NSSize(width: 640, height: 1800), style: style, dark: dark,
                        file: directory.appendingPathComponent("general-" + suffix))
                    try await TypefluxUISnapshot.render(AppearanceSettingsView(viewModel: model),
                        size: NSSize(width: 640, height: 760), style: style, dark: dark,
                        file: directory.appendingPathComponent("appearance-" + suffix))
                    try await TypefluxUISnapshot.render(AdvancedSettingsView(viewModel: model),
                        size: NSSize(width: 640, height: 540), style: style, dark: dark,
                        file: directory.appendingPathComponent("advanced-" + suffix))
                    try await TypefluxUISnapshot.render(HotkeySettingsView(viewModel: model, settingsStore: settings),
                        size: NSSize(width: 640, height: 1400), style: style, dark: dark,
                        file: directory.appendingPathComponent("shortcuts-" + suffix))
                    let fixture = AccountViewRenderingTests.Fixture()
                    fixture.subscription = AccountViewRenderingTests.snapshot(plan: "pro", status: "active", paid: true)
                    fixture.credits = CloudCreditSummary(limit: 2_000_000, used: 500_000, remaining: 1_500_000,
                        unlimited: false, addon: CloudAddonCredits(
                            balance: 20_000, usedThisPeriod: 0, remaining: 20_000,
                            nextExpiry: CloudAddonExpiry(credits: 20_000, expiresAt: "2026-11-01T00:00:00Z")))
                    fixture.breakdown = CloudUsageBreakdown(periodStart: AccountViewRenderingTests.start,
                        periodEnd: AccountViewRenderingTests.end, timezone: "UTC",
                        days: [.init(date: "2026-10-01", voice: 30, rewrite: 10, ask: 5)],
                        voice: 30, rewrite: 10, ask: 5)
                    let auth = AccountViewRenderingTests().makeAuth(fixture)
                    await auth.refreshSubscription()
                    await auth.refreshUsage()
                    await auth.refreshUsageBreakdown()
                    try await TypefluxUISnapshot.render(AccountView(authState: auth, onLogout: {}),
                        size: NSSize(width: 640, height: 1500), style: style, dark: dark,
                        file: directory.appendingPathComponent("account-" + suffix))
                }
            }
        }
    }
}
