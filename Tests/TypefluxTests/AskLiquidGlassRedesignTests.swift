import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask Liquid Glass redesign")
struct AskLiquidGlassRedesignTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func summary(_ id: String, _ title: String, _ offset: TimeInterval = 0) -> AskConversationSummary {
        AskConversationSummary(id: id, title: title, updatedAt: Self.now.addingTimeInterval(offset))
    }

    private var history: [AskConversationSummary] {
        [summary("a", "讲讲这一屏在做什么"), summary("b", "Swift actor reentrancy"), summary("c", "早上好呀")]
    }

    // MARK: - Palette

    @Test func emptyQueryListsEveryActionThenEveryConversation() {
        let state = AskPaletteState.make(query: "", conversations: history, title: { $0.rawValue })
        #expect(state.actions == AskPaletteAction.allCases.map(AskPaletteRow.action))
        #expect(state.conversations.count == 3)
        #expect(state.highlighted == 0)
        #expect(state.highlightedRow == .action(.newConversation))
    }

    @Test func typedQueryHighlightsTheFirstMatchingConversation() {
        let state = AskPaletteState.make(query: "  swift ", conversations: history, title: { $0.rawValue })
        #expect(state.actions.isEmpty)
        #expect(state.conversations == [.conversation(history[1])])
        #expect(state.highlightedRow == .conversation(history[1]))
    }

    @Test func typedQueryMatchingOnlyAnActionHighlightsIt() {
        let state = AskPaletteState.make(query: "sidebar", conversations: history, title: { $0.rawValue })
        #expect(state.rows == [.action(.toggleSidebar)])
        #expect(state.highlighted == 0)
    }

    @Test func actionsOutsideTheAvailableListAreNotOffered() {
        let state = AskPaletteState.make(query: "", conversations: [], available: [.newConversation],
                                         title: { $0.rawValue })
        #expect(state.rows == [.action(.newConversation)])
    }

    @Test func noMatchesHighlightsNothing() {
        var state = AskPaletteState.make(query: "zzz", conversations: history, title: { $0.rawValue })
        #expect(state.rows.isEmpty)
        #expect(state.highlighted == nil)
        #expect(state.highlightedRow == nil)
        state.move(1)
        #expect(state.highlighted == nil)
    }

    @Test func arrowMovesWrapAtBothEnds() {
        var state = AskPaletteState.make(query: "", conversations: history, available: [.newConversation],
                                         title: { $0.rawValue })
        #expect(state.rows.count == 4)
        state.move(-1)
        #expect(state.highlighted == 3)
        state.move(1)
        #expect(state.highlighted == 0)
        state.move(2)
        #expect(state.highlighted == 2)
        state.highlighted = nil
        state.move(1)
        #expect(state.highlighted == 0)
        state.highlighted = nil
        state.move(-1)
        #expect(state.highlighted == 3)
    }

    @Test func outOfRangeHighlightResolvesToNoRow() {
        var state = AskPaletteState.make(query: "", conversations: [], available: [.usage], title: { $0.rawValue })
        state.highlighted = 9
        #expect(state.highlightedRow == nil)
    }

    @Test func paletteActionsHaveTitlesSymbolsAndStableIDs() {
        for action in AskPaletteAction.allCases {
            #expect(L(action.titleKey) != action.titleKey)
            #expect(NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil) != nil)
            #expect(AskPaletteRow.action(action).id == "action:" + action.rawValue)
        }
        #expect(AskPaletteAction.newConversation.shortcut == "⌘N")
        #expect(AskPaletteAction.toggleSidebar.shortcut == "⌃⌘S")
        #expect(AskPaletteAction.usage.shortcut == nil)
        #expect(AskPaletteRow.conversation(history[0]).id == "conversation:a")
        #expect(L("ask.search.placeholder") != "ask.search.placeholder")
    }

    @Test func arrowKeysMapToHighlightSteps() {
        #expect(AskArrowKeyMonitor.delta(keyCode: AskArrowKeyMonitor.upKeyCode, modifiers: []) == -1)
        #expect(AskArrowKeyMonitor.delta(keyCode: AskArrowKeyMonitor.downKeyCode, modifiers: []) == 1)
        #expect(AskArrowKeyMonitor.delta(keyCode: AskArrowKeyMonitor.downKeyCode, modifiers: .numericPad) == 1)
        #expect(AskArrowKeyMonitor.delta(keyCode: AskArrowKeyMonitor.downKeyCode, modifiers: .shift) == nil)
        #expect(AskArrowKeyMonitor.delta(keyCode: AskArrowKeyMonitor.upKeyCode, modifiers: .command) == nil)
        #expect(AskArrowKeyMonitor.delta(keyCode: 36, modifiers: []) == nil)
    }

    // MARK: - Header and composer state

    @Test func runToneFollowsTheRunAndPendingApproval() {
        var run = AskRun(id: "r", deviceId: "d", status: "running", steps: 1, updatedAt: Self.now, tools: [], pending: [])
        #expect(AskRunTone.of(nil, pendingApproval: true) == nil)
        #expect(AskRunTone.of(run, pendingApproval: false) == .running)
        #expect(AskRunTone.of(run, pendingApproval: true) == .attention)
        run.status = "waiting_tool"
        #expect(AskRunTone.of(run, pendingApproval: false) == .running)
        run.status = "completed"
        #expect(AskRunTone.of(run, pendingApproval: false) == .done)
        run.status = "failed"
        #expect(AskRunTone.of(run, pendingApproval: false) == .failed)
        run.status = "cancelled"
        #expect(AskRunTone.of(run, pendingApproval: false) == .failed)
        run.status = "unknown"
        #expect(AskRunTone.of(run, pendingApproval: false) == nil)
    }

    @Test func toneDotColoursAndMotion() {
        #expect(AskRunToneDot.color(.done) == StudioTheme.success)
        #expect(AskRunToneDot.color(.running) == AskTheme.accent)
        #expect(AskRunToneDot.color(.attention) == StudioTheme.warning)
        #expect(AskRunToneDot.color(.failed) == StudioTheme.danger)
        #expect(AskRunToneDot.pulses(.running, reduceMotion: false))
        #expect(!AskRunToneDot.pulses(.running, reduceMotion: true))
        #expect(!AskRunToneDot.pulses(.done, reduceMotion: false))
    }

    @Test func sendControlTurnsIntoStopOnlyWhileBusyWithNothingTyped() {
        #expect(AskSendControl.resolve(busy: true, hasDraft: false, canSend: false, editingQueued: false) == .stop)
        // A typed follow-up queues behind the run.
        #expect(AskSendControl.resolve(busy: true, hasDraft: true, canSend: true, editingQueued: false)
            == .send(enabled: true))
        #expect(AskSendControl.resolve(busy: true, hasDraft: true, canSend: false, editingQueued: false)
            == .send(enabled: false))
        // Editing a queued message keeps its own save actions, never Stop.
        #expect(AskSendControl.resolve(busy: true, hasDraft: false, canSend: false, editingQueued: true)
            == .send(enabled: false))
        #expect(AskSendControl.resolve(busy: false, hasDraft: false, canSend: false, editingQueued: false)
            == .send(enabled: false))
        #expect(AskSendControl.resolve(busy: false, hasDraft: true, canSend: true, editingQueued: false)
            == .send(enabled: true))
    }

    @Test func headerInk() {
        #expect(AskHeaderIconButton.ink(active: true, hovering: false) == AskTheme.accent)
        #expect(AskHeaderIconButton.ink(active: false, hovering: true) == StudioTheme.textPrimary)
        #expect(AskHeaderIconButton.ink(active: false, hovering: false) == StudioTheme.textSecondary)
    }

    @Test func pressStylesScaleGently() {
        #expect(AskPressableStyle().scale == AskPressableStyle.pressedScale)
        #expect(AskPressableStyle.subtle.scale > AskPressableStyle.pressedScale)
        #expect(AskPressableStyle.subtle.scale < 1)
    }

    // MARK: - History labels

    @Test func historyLabelShowsTimeForRecentDaysAndDateForOlderOnes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US_POSIX")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 19, minute: 5)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9, minute: 7)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 20, minute: 27)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8)))
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 8)))
        let label = { (date: Date) in
            AskPresentation.historyTimeLabel(date, now: now, calendar: calendar, locale: locale)
        }
        #expect(label(today).contains("9:07"))
        #expect(label(yesterday).contains("8:27"))
        #expect(label(earlier) == "Sep 28")
        #expect(label(lastYear).contains("2025"))
    }

    @Test func chineseHistoryLabelUsesMonthAndDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 19)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8)))
        #expect(AskPresentation.historyTimeLabel(earlier, now: now, calendar: calendar,
                                                 locale: Locale(identifier: "zh_Hans")) == "9月28日")
    }

    // MARK: - Attachment strip

    @Test func stripListsOnlyContentThatIsSent() {
        let attached = AskContextChips.items(screenshot: .attached, source: "Chrome — GUL-155", sourceBundleID: nil,
                                             selection: "a\nb", selectionOff: false, memory: nil, memoryPinned: true)
        // Memory is a setting: its lit footer toggle is enough, so the strip leaves it out.
        let strip = AskAttachmentStrip.attached(attached, screenshotCaptured: true)
        #expect(strip.map(\.kind) == [.screenshot, .source, .selection])
        // Being in the strip already says "attached"; the label just names the item.
        #expect(strip.first?.title == L("ask.context.screenshot"))
        #expect(strip.first?.title != L("ask.context.screenshot.attached"))
        // The footer chip keeps describing the state in its hover card.
        #expect(attached.first?.title == L("ask.context.screenshot.attached"))

        // Switched on but not captured yet: nothing to show until the image arrives.
        #expect(AskAttachmentStrip.attached(attached, screenshotCaptured: false).map(\.kind) == [.source, .selection])

        let off = AskContextChips.items(screenshot: .off, source: nil, sourceBundleID: nil,
                                        selection: "a", selectionOff: true, memory: nil, memoryOff: true,
                                        memoryPinned: true)
        #expect(AskAttachmentStrip.attached(off, screenshotCaptured: true).isEmpty)

        let memoryOnly = AskContextChips.items(screenshot: .off, source: nil, sourceBundleID: nil,
                                               selection: nil, memory: nil, memoryPinned: true)
        #expect(memoryOnly.contains { $0.kind == .memory && $0.style == .active })
        #expect(AskAttachmentStrip.attached(memoryOnly, screenshotCaptured: false).isEmpty)

        let failed = AskContextChips.items(screenshot: .failed(permission: true, message: "x"), source: nil,
                                           sourceBundleID: nil, selection: nil, memory: nil, memoryPinned: false)
        #expect(AskAttachmentStrip.attached(failed, screenshotCaptured: true).isEmpty)
        let unavailable = AskContextChips.items(screenshot: .unavailable(reason: "no vision"), source: nil,
                                                sourceBundleID: nil, selection: nil, memory: nil, memoryPinned: false)
        #expect(AskAttachmentStrip.attached(unavailable, screenshotCaptured: true).isEmpty)
    }

    @MainActor @Test func screenshotThumbnailIsDecodedOncePerCapture() {
        var decodes = 0
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let decode: (String) -> NSImage? = { _ in decodes += 1; return image }
        let first = Date(timeIntervalSince1970: 1)
        #expect(AskAttachmentStrip.thumbnail(dataURL: nil, capturedAt: first, decode: decode) == nil)
        #expect(AskAttachmentStrip.thumbnail(dataURL: "data:a", capturedAt: first, decode: decode) === image)
        #expect(AskAttachmentStrip.thumbnail(dataURL: "data:a", capturedAt: first, decode: decode) === image)
        #expect(decodes == 1)
        // A new capture decodes again.
        _ = AskAttachmentStrip.thumbnail(dataURL: "data:a", capturedAt: Date(timeIntervalSince1970: 2), decode: decode)
        #expect(decodes == 2)
        _ = AskAttachmentStrip.thumbnail(dataURL: "data:ab", capturedAt: Date(timeIntervalSince1970: 2), decode: decode)
        #expect(decodes == 3)
    }
}
