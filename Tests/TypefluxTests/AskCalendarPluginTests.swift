import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Calendar keyword registration", .serialized, .exclusiveUIState)
@MainActor
struct AskCalendarPluginTests {
    @Test func `keyword aliases migrate and respect conflicts`() {
        #expect(AskPluginRegistry.pluginIDs.contains(AskCalendarPlugin.id))
        let defaults = AskPluginRegistry.defaultKeywords.filter { $0.pluginID == AskCalendarPlugin.id }
        #expect(defaults.map(\.allKeywords) == [["cal", "日历", "rl", "calendar"]])
        for word in ["cal", "日历", "rl", "calendar"] {
            #expect(AskKeywordMatcher.match(word, keywords: defaults) == .hint(defaults[0]))
            #expect(AskKeywordMatcher.match(word + " 下周五", keywords: defaults) == .active(defaults[0], argument: "下周五"))
        }
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskCalendarPlugin.id }
        let migrated = AskPluginRegistry.keywords(saved: [AskKeyword(keyword: "cal", pluginID: "custom")], known: known)
        #expect(migrated.contains { $0.pluginID == AskCalendarPlugin.id && $0.keyword == "日历" && !$0.contains("cal") })
        #expect(AskPluginRegistry.keywords(saved: [], known: AskPluginRegistry.coveredGroups).isEmpty)
        #expect(AskKeywordKind(pluginID: AskCalendarPlugin.id) == .calendar)
        #expect(AskKeywordKind.calendar.pluginID == AskCalendarPlugin.id)
        #expect(AskKeywordKind.calendar.symbol == "calendar")
        #expect(!AskKeywordKind.calendar.title.isEmpty && !AskKeywordKind.calendar.hint.isEmpty)
        let draft = AskKeywordDraft(editing: .init(keyword: "cal", pluginID: AskCalendarPlugin.id,
                                                   options: ["calendar.weeks": "true", "custom": "kept"]))
        #expect(draft.kind == .calendar && draft.fieldProblem == nil && draft.titlePlaceholder.isEmpty)
        #expect(draft.result().options == ["calendar.weeks": "true", "custom": "kept"])
        #expect(!draft.displayName.isEmpty)
        #expect(!AskKeywordListPresentation.name(of: defaults[0]).isEmpty)
        #expect(!AskKeywordListPresentation.summary(of: defaults[0], interface: .english, secondLanguage: "en").isEmpty)
    }

    @Test func `plugin runs locally without selected text`() async throws {
        let plugin = AskCalendarPlugin()
        #expect(plugin.entersOnReturn && plugin.runsWithoutInput && !plugin.usesSelectionInput)
        #expect(plugin.defaultKeywords == AskCalendarPlugin.keywords)
        #expect(plugin.symbol == "calendar" && !plugin.title.isEmpty)
        // Red is reserved for destructive keywords such as `kill`.
        #expect(plugin.keywordColor == AskTheme.accent)
        #expect(!plugin.placeholder(selectionLines: nil).isEmpty)
        #expect(plugin.chipDetail(for: plugin.defaultKeywords[0], language: .english) == nil)
        let request = AskPluginRequest(
            text: "明天",
            origin: .argument,
            keyword: plugin.defaultKeywords[0],
            options: [:],
            interfaceLanguage: .english
        )
        let plan = await plugin.plan(request)
        #expect(plan.mode == .live && plan.debounce == .zero)
        let result = try await plugin.run(request, plan: plan, progress: { _ in })
        #expect(result.body == "明天")
        var selection = request
        selection.origin = .selection
        #expect(try await plugin.run(selection, plan: plan, progress: { _ in }).body.isEmpty)
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
        #expect(!AskCalendarPlugin.summary(now: CalendarFixtures.date(), language: .simplifiedChinese).isEmpty)
        #expect(!AskCalendarPlugin.summary(now: CalendarFixtures.date(), language: .english).isEmpty)
    }

    @Test func `conversation enters from aliases and persists hidden events`() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); fixture.model.calendarLauncher.close() }
        let model = fixture.model
        model.launcherDraft.text = "rl 下周五"
        #expect(model.enterLauncherKeywordFromText(pluginID: AskCalendarPlugin.id))
        #expect(model.plugins.keyword?.pluginID == AskCalendarPlugin.id)
        #expect(model.launcherDraft.text == "下周五")
        #expect(model.makeLauncherPlugins().contains { $0.id == AskCalendarPlugin.id })
        #expect(model.launcherSearchEntries(language: .english)
            .contains { $0.keyword.pluginID == AskCalendarPlugin.id })
        #expect(model.performCalendarEffect(.handled) == .stay)
        #expect(model.performCalendarEffect(.unhandled) == .stay)
        model.hideCalendarEvents()
        #expect(model.modelLibrary.settings.effectiveAskLauncherKeywords.first { $0.pluginID == AskCalendarPlugin.id }?
            .options["calendar.events"] == "false")
        #expect(!model.calendarLauncher.preferences.showsEvents)
        _ = model.performCalendarEffect(.clearInput)
        #expect(model.launcherDraft.text.isEmpty)
    }

    @Test func `native keys map without stealing modified text selection`() throws {
        for (code, flags, expected) in [(UInt16(123), NSEvent.ModifierFlags(), AskCommandKey.left),
                                        (123, .command, .commandLeft), (124, .command, .commandRight),
                                        (17, .command, .commandT), (45, .command, .commandN)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                      timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            #expect(AskCommandKey(event) == expected)
        }
        let shifted = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        #expect(AskCommandKey(shifted) == nil)
    }

    @Test func `hint includes the next upcoming event`() {
        let dates = CalendarFixtures.dates, now = CalendarFixtures.date().addingTimeInterval(10 * 3600)
        #expect(CalendarHintSummary.eventSummary([], now: now, dates: dates).isEmpty)
        let summary = CalendarHintSummary.eventSummary(CalendarFixtures.events, now: now, dates: dates)
        #expect(summary.contains("Calendar review"))
        #expect(!summary.contains("Standup"))
        let past = CalendarHintSummary.eventSummary(
            CalendarFixtures.events,
            now: dates.adding(1, to: now),
            dates: dates
        )
        #expect(!past.contains("Calendar review"))
    }
}
