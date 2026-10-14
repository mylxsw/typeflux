import AppKit
import Testing
@testable import Typeflux

@Suite("Calendar navigation from the real editor", .serialized, .exclusiveUIState)
@MainActor
struct AskCalendarKeyboardTests {
    @Test func `entry navigation copy and escape stay local`() async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "cal", prepare: { model in
                model.calendarLauncher = CalendarLauncherModel(
                    provider: FakeCalendarEventProvider(),
                    dates: CalendarFixtures.dates,
                    now: { CalendarFixtures.date().addingTimeInterval(10 * 3600) }
                )
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.press(36)
            #expect(model.plugins.keyword?.pluginID == AskCalendarPlugin.id)
            #expect(model.launcherDraft.text.isEmpty)
            try await launcher.press(124)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date(2026, 10, 15))
            try await launcher.press(123)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date())
            try await launcher.press(125)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date(2026, 10, 21))
            try await launcher.press(17, .command)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date())
            try await launcher.press(124, .command)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date(2026, 11, 14))
            try await launcher.press(123, .command)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date())
            try await launcher.press(8, .command)
            #expect(pasteboard.string(forType: .string) == model.calendarLauncher.copiedDate)
            #expect(launcher.dismissed == 0)
            try await launcher.press(48)
            #expect(model.calendarLauncher.chosenEvent?.id == "review")
            try await launcher.press(53)
            #expect(!model.calendarLauncher.eventFocus && model.plugins.isActive)
            model.launcherDraft.text = "春节"
            try await Task.sleep(for: .milliseconds(80))
            #expect(model.calendarLauncher.selected == CalendarFixtures.date(2027, 2, 6))
            try await launcher.press(53)
            #expect(model.launcherDraft.text.isEmpty && model.plugins.isActive)
            #expect(model.calendarLauncher.selected == CalendarFixtures.date(2027, 2, 6))
            try await launcher.press(53)
            #expect(!model.plugins.isActive && model.launcherDraft.text == "cal")
            try await launcher.press(53)
            #expect(launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `dates leave nonempty editor caret movement alone and open actions use the selection`() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "cal today",
            waitForSearch: false,
            prepare: { model in
                model.calendarLauncher = CalendarLauncherModel(
                    provider: FakeCalendarEventProvider(),
                    dates: CalendarFixtures.dates,
                    now: { CalendarFixtures.date().addingTimeInterval(10 * 3600) }
                )
            }
        )
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await launcher.fixture
            .wait { model.plugins.isActive && model.calendarLauncher.selected == CalendarFixtures.date() }
        launcher.editor.setSelectedRange(NSRange(location: 2, length: 0))
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: launcher.window.windowNumber, context: nil,
                                                 characters: "\u{f702}",
                                                 charactersIgnoringModifiers: "\u{f702}", isARepeat: false,
                                                 keyCode: 123))
        launcher.editor.keyDown(with: left)
        #expect(launcher.editor.selectedRange().location == 1)
        #expect(model.calendarLauncher.selected == CalendarFixtures.date())
        var opened: [URL] = []
        model.calendarLauncher.openURL = { opened.append($0); return true }
        try await launcher.fixture
            .wait { !model.calendarLauncher.loading && model.calendarLauncher.dayEvents.count == 3 }
        try await launcher.press(48)
        try await launcher.press(31, .command)
        #expect(opened.first == CalendarLinks.event(CalendarFixtures.events[1]))
        #expect(launcher.dismissed == 1)
    }

    @Test func `event open failure falls back without closing on total failure`() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var opened: [URL] = []
        model.calendarLauncher.openURL = { opened.append($0); return false }
        let event = CalendarFixtures.events[1]
        #expect(model.performCalendarEffect(.open(event.start, event: event, join: true)) == .stay)
        #expect(try opened == [#require(event.meeting), CalendarLinks.day(event.start)])
        opened = []
        #expect(model.performCalendarEffect(.open(event.start, event: nil, join: false)) == .stay)
        #expect(opened == [CalendarLinks.day(event.start)])
        opened = []
        model.calendarLauncher.openURL = { opened.append($0); return opened.count == 2 }
        #expect(model.performCalendarEffect(.open(event.start, event: event, join: false)) == .close)
        #expect(opened == [CalendarLinks.event(event), CalendarLinks.day(event.start)])
        model.calendarLauncher.openURL = { opened.append($0); return true }
        #expect(model.performCalendarEffect(.settings) == .stay)
        #expect(opened.last?.scheme == "x-apple.systempreferences")
        model.hideCalendarEvents()
    }

    @Test func `selecting the calendar application does not enter the keyword`() async throws {
        let app = AskTestAppIndex.app("Calendar")
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "calendar",
            apps: AskTestAppIndex([app]),
            prepare: { model in
                model
                    .calendarLauncher =
                    CalendarLauncherModel(
                        provider: FakeCalendarEventProvider(
                        ),
                        dates: CalendarFixtures.dates,
                        now: { CalendarFixtures.date() }
                    )
            }
        )
        defer { launcher.close() }
        #expect(launcher.fixture.model.quickSearch.results?.rows.prefix(2) == [.feature(0), .app(0)])
        try await launcher.press(125)
        try await launcher.press(36)
        #expect(launcher.opened == [app.url])
        #expect(!launcher.fixture.model.plugins.isActive)
        #expect(launcher.dismissed == 1)
    }

    @Test func `navigation keys do not block caret movement in pending app search`() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let index = AskControlledSearchIndex()
        index.appSearch = { query in
            if query != "zzfinder" {
                _ = gate.wait(timeout: .now() + 5)
            }
            return [.init(entry: AskTestAppIndex.app("ZZFinder"), score: 1)]
        }
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "zzfinder", prepare: { model in
            model.appIndex = index
            model.modelLibrary.settings.askQuickFileSearchEnabled = false
        })
        defer { launcher.close() }
        launcher.fixture.model.launcherDraft.text = "waiting"
        try await launcher.fixture.wait { launcher.fixture.model.quickSearch.pendingResults != nil }
        launcher.editor.setSelectedRange(NSRange(location: 4, length: 0))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: launcher.window.windowNumber, context: nil,
                                                  characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}",
                                                  isARepeat: false, keyCode: 123))
        launcher.editor.keyDown(with: event)
        #expect(launcher.editor.selectedRange().location == 3)
        #expect(launcher.dismissed == 0 && launcher.opened.isEmpty)
    }
}
