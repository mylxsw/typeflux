import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Mobile history presentation")
struct ChatPresentationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func `history sections respect day boundaries and sort newest first`() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 1)))
        let start = calendar.startOfDay(for: now)
        let items = [
            ChatConversationSummary(id: "old", title: "Earlier", updatedAt: start.addingTimeInterval(-86401)),
            ChatConversationSummary(id: "first", title: "Swift Notes", updatedAt: start),
            ChatConversationSummary(id: "last", title: "Swift concurrency", updatedAt: now),
            ChatConversationSummary(id: "yesterday", title: "Design", updatedAt: start.addingTimeInterval(-1))
        ]
        #expect(ChatPresentation.history(items, matching: " swift ", section: .today, now: now, calendar: calendar)
            .map(\.id) == ["last", "first"])
        #expect(ChatPresentation.history(items, matching: "", section: .yesterday, now: now, calendar: calendar)
            .map(\.id) == ["yesterday"])
        #expect(ChatPresentation.history(items, matching: "", section: .earlier, now: now, calendar: calendar)
            .map(\.id) == ["old"])
        #expect(ChatPresentation.history(items, matching: "missing", section: .today, now: now, calendar: calendar)
            .isEmpty)
        #expect(ChatHistorySection.allCases.map(\.title) == ["Today", "Yesterday", "Earlier"])
    }

    @Test func `search empty state shares the list normalization`() {
        let item = ChatConversationSummary(id: "match", title: "Swift notes", updatedAt: Date())
        #expect(ChatPresentation.matches(item, query: " swift "))
        #expect(ChatPresentation.matches(item, query: "   "))
        #expect(!ChatPresentation.matches(item, query: "nothing"))
    }

    @Test func `header distinguishes stopped and failed runs from completion`() {
        for (status, title) in [("failed", "Failed"), ("cancelled", "Stopped"), ("completed", "Completed"),
                                ("running", "Running"), ("waiting_tool", "Waiting for Mac"),
                                ("waiting_inference", "Waiting for Mac")] {
            #expect(ChatPresentation.runTitle(ChatRun(id: "run", deviceId: "test", status: status)) == title)
        }
    }

    @Test func `quoting preserves unfinished draft and bounds long responses`() {
        #expect(ChatPresentation.quote("one\ntwo", into: "Draft\n") == "Draft\n\n> one\n> two\n\n")
        #expect(ChatPresentation.quote("one", into: "") == "> one\n\n")
        #expect(ChatPresentation.quote("1\n2\n3\n4\n5\n6\n7", into: "").hasSuffix("> 6\n> …\n\n"))
    }

    @Test func `cancelled runs show a neutral notice even when the server supplies error text`() {
        for error in [nil, "Response stopped.", "Operation cancelled", ""] as [String?] {
            let run = ChatRun(id: "stop", deviceId: "test", status: "cancelled", error: error)
            #expect(ChatPresentation.runNotice(run) == .stopped)
        }
    }

    @Test func `run failures retain actionable details and missing details get a fallback`() {
        let failed = ChatRun(id: "failure", deviceId: "test", status: "failed", error: "  Connection lost.\n")
        #expect(ChatPresentation.runNotice(failed) == .failure("Connection lost."))
        for error in [nil, "", " \n"] as [String?] {
            let run = ChatRun(id: "failure", deviceId: "test", status: "failed", error: error)
            #expect(ChatPresentation.runNotice(run) == .failure("The server could not complete this request."))
        }
        for status in ["running", "completed", "waiting_tool"] {
            let run = ChatRun(id: "healthy", deviceId: "test", status: status)
            #expect(ChatPresentation.runNotice(run) == nil)
        }
    }

    @Test func `horizontal hint follows actual overflow including rotation and initial measurement`() {
        #expect(ChatPresentation.hasHorizontalOverflow(contentWidth: 600, viewportWidth: 360))
        #expect(!ChatPresentation.hasHorizontalOverflow(contentWidth: 600, viewportWidth: 780))
        #expect(!ChatPresentation.hasHorizontalOverflow(contentWidth: 360, viewportWidth: 360))
        #expect(!ChatPresentation.hasHorizontalOverflow(contentWidth: 360.5, viewportWidth: 360))
        #expect(!ChatPresentation.hasHorizontalOverflow(contentWidth: 600, viewportWidth: 0))
        #expect(!ChatPresentation.hasHorizontalOverflow(contentWidth: .infinity, viewportWidth: 360))
        #expect(!ChatPresentation.hasHorizontalOverflow(contentWidth: 600, viewportWidth: .nan))
    }
}
