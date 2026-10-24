import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct PermissionGuidanceServiceTests {
    @MainActor
    private final class Fixture {
        var granted: Set<SettingsPermission> = []
        var shown: [SettingsPermission] = []
        var apps: [URL] = []
        var locales: [String] = []
        var opened: [URL] = []
        var closes = 0
        var app = URL(fileURLWithPath: "/Applications/Typeflux Dev.app")
        var language = "zh-Hans"
        var time = Date()
        lazy var service = PermissionGuidanceService(
            isGranted: { [unowned self] in self.granted.contains($0) },
            present: { [unowned self] in self.shown.append($0); self.apps.append($1); self.locales.append($2) },
            close: { [unowned self] in self.closes += 1 },
            updateLocale: { [unowned self] in self.locales.append($0) },
            openURL: { [unowned self] in self.opened.append($0) },
            bundleURL: { [unowned self] in self.app }, locale: { [unowned self] in self.language },
            now: { [unowned self] in self.time }, monitorsSystem: false
        )
    }

    @Test func missingDragPermissionsUseCurrentAppAndLocale() {
        for permission in [SettingsPermission.accessibility, .screenRecording, .fullDiskAccess] {
            let fixture = Fixture()
            fixture.service.open(permission.settingsURL)
            #expect(fixture.shown == [permission])
            #expect(fixture.apps == [fixture.app])
            #expect(fixture.locales == ["zh-Hans"])
            #expect(fixture.opened.isEmpty)
            #expect(fixture.service.activePermission == permission)
            fixture.service.dismiss()
        }
    }

    @Test func grantedAndNonAppHostsOnlyNavigate() {
        let fixture = Fixture()
        fixture.granted = [.accessibility, .screenRecording, .fullDiskAccess]
        for permission in fixture.granted { fixture.service.show(permission) }
        #expect(fixture.opened.count == 3)
        fixture.granted = []
        fixture.app = URL(fileURLWithPath: "/tmp/TypefluxTests.xctest")
        fixture.service.show(.accessibility)
        #expect(fixture.opened.last == SettingsPermission.accessibility.settingsURL)
        #expect(fixture.shown.isEmpty)
        #expect(fixture.service.activePermission == nil)
    }

    @Test func otherPermissionsAndOrdinaryURLsOnlyNavigate() {
        let fixture = Fixture()
        let permissions: [SettingsPermission] = [.microphone, .speechRecognition, .camera,
                                                 .calendar, .notifications, .automation]
        for permission in permissions { fixture.service.open(permission.settingsURL) }
        let web = URL(string: "https://example.com")!
        fixture.service.open(web)
        #expect(fixture.opened == permissions.map(\.settingsURL) + [web])
        #expect(fixture.shown.isEmpty)
    }

    @Test func switchingOrOpeningOrdinaryPermissionClosesPreviousGuide() {
        let fixture = Fixture()
        fixture.service.show(.accessibility)
        fixture.service.show(.fullDiskAccess)
        #expect(fixture.closes == 1)
        #expect(fixture.service.activePermission == .fullDiskAccess)
        fixture.service.show(.microphone)
        #expect(fixture.closes == 2)
        #expect(fixture.service.activePermission == nil)
        fixture.service.dismiss()
        #expect(fixture.closes == 2)
    }

    @Test func refreshRequiresActualGrantAndUpdatesLanguage() {
        let fixture = Fixture()
        fixture.service.show(.accessibility)
        fixture.language = "en"
        fixture.service.refresh()
        #expect(fixture.locales.last == "en")
        #expect(fixture.closes == 0)
        fixture.granted.insert(.accessibility)
        fixture.service.refresh()
        #expect(fixture.closes == 1)
        #expect(fixture.service.activePermission == nil)
        fixture.service.refresh()
        #expect(fixture.closes == 1)
    }

    @Test func abandonedGuidanceExpiresWithoutReportingGrant() {
        let fixture = Fixture()
        fixture.service.show(.screenRecording)
        fixture.time = fixture.time.addingTimeInterval(301)
        fixture.service.refresh()
        #expect(fixture.closes == 1)
        #expect(fixture.service.activePermission == nil)
        #expect(fixture.granted.isEmpty)
    }

    @Test func returningToAppDismissesAndUnsubscribes() {
        var closes = 0
        let service = PermissionGuidanceService(
            isGranted: { _ in false }, present: { _, _, _ in }, close: { closes += 1 },
            updateLocale: { _ in }, openURL: { _ in },
            bundleURL: { URL(fileURLWithPath: "/Applications/Typeflux.app") }, locale: { "en" }
        )
        service.show(.accessibility)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(closes == 1)
        #expect(service.activePermission == nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(closes == 1)
    }
}
