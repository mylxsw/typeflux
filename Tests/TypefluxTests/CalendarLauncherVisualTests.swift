import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Calendar launcher visuals", .serialized, .exclusiveUIState)
@MainActor
struct CalendarLauncherVisualTests {
    @Test func `renders approved states in the production launcher`() async throws {
        _ = NSApplication.shared
        let old = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(old) }
        for (scene, text, light, access) in [
            ("month", "", false, CalendarAccess.allowed), ("agenda", "", false, .allowed),
            ("jump", "春节", false, .allowed), ("range", "今天到12-31", false, .allowed),
            ("year", "2027", false, .allowed), ("past-year", "2025-12-13", false, .allowed),
            ("estimated", "今天到2027-02-06", false, .allowed), ("weeks", "", false, .allowed), (
                "search",
                "评审",
                false,
                .allowed
            ),
            ("permission", "", false, .unknown), ("events-off", "评审", false, .unknown), ("denied", "", false, .denied),
            ("invalid", "2-30", false, .allowed), ("light-month", "", true, .allowed),
            ("light-agenda", "", true, .allowed)
        ] {
            let fixture = try AskTestFixture()
            var events = CalendarFixtures.events
            events[0].title = "产品站会"
            events[0].start = CalendarFixtures.date().addingTimeInterval(10 * 3600)
            events[0].end = CalendarFixtures.date().addingTimeInterval(10.5 * 3600)
            events[1].title = "设计评审：日历功能"
            events[1].attendees = 6
            events[1].organizer = "示例"
            events[2].title = "羽毛球"
            let calendar = CalendarLauncherModel(provider: FakeCalendarEventProvider(access: access, events: events),
                                                 dates: CalendarFixtures.dates,
                                                 now: { CalendarFixtures.date().addingTimeInterval(10 * 3600 + 24 * 60)
                                                 })
            fixture.model.calendarLauncher = calendar
            var keyword = try #require(fixture.model.plugins.availableKeywords
                .first { $0.pluginID == AskCalendarPlugin.id })
            if scene == "weeks" {
                keyword.options["calendar.weeks"] = "true"
            }
            if scene == "events-off" {
                keyword.options["calendar.events"] = "false"
            }
            fixture.model.plugins.enter(keyword)
            fixture.model.launcherDraft.text = text
            let size = NSSize(width: AskMetrics.launcherWidth, height: 536)
            let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                            backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            let host = NSHostingView(rootView: AskLauncherView(
                model: fixture.model,
                onDismiss: {},
                onHeightChange: { _ in }
            ))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { calendar.close(); window.close(); fixture.model.resetSession() }
            try await fixture.wait { calendar.access == access && !calendar.loading }
            if access == .allowed, text.isEmpty {
                #expect(calendar.dayEvents.count == 3)
            }
            if scene.contains("agenda") {
                calendar.selectEvent("review")
                #expect(calendar.chosenEvent?.id == "review")
            }
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 680 && bitmap.pixelsHigh >= 500)
            #expect(calendar.query == CalendarQueryParser(today: CalendarFixtures.date(), dates: CalendarFixtures.dates)
                .parse(text))
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CALENDAR_SNAPSHOTS"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent(scene + ".png"))
            }
        }
    }
}
