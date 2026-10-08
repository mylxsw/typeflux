import Foundation
import SwiftUI
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

    @Test func `title pill status counts the latest turn's steps`() {
        let search = ChatToolCall(id: "s", function: .init(name: "web_search", arguments: #"{"query":"q"}"#))
        let fetch = ChatToolCall(id: "f", function: .init(name: "web_fetch", arguments: "{}"))
        let old = ChatToolCall(id: "old", function: .init(name: "web_search", arguments: "{}"))
        var conversation = ChatConversation(id: "c", title: "T", revision: 1, messages: [
            ChatMessage(id: "q0", role: "user", text: "Earlier"),
            ChatMessage(id: "a0", role: "assistant", text: "", toolCalls: [old]),
            ChatMessage(id: "q1", role: "user", text: "Now"),
            ChatMessage(id: "a1", role: "assistant", text: "", toolCalls: [search])
        ])
        conversation.run = ChatRun(id: "r", deviceId: "d", status: "running", pending: [search, fetch])
        #expect(ChatTranscript.stepCount(conversation) == 2)
        #expect(ChatPresentation.runStatusLine(conversation.run!, steps: 2) == "Running · Step 2")
        conversation.run?.status = "completed"
        #expect(ChatTranscript.stepCount(conversation) == 1)
        #expect(ChatPresentation.runStatusLine(conversation.run!, steps: 1) == "Completed · 1 steps")
        #expect(ChatPresentation.runStatusLine(conversation.run!, steps: 0) == "Completed")
        conversation.run?.status = "failed"
        #expect(ChatPresentation.runStatusLine(conversation.run!, steps: 3) == "Failed")
        conversation.run?.status = "waiting_tool"
        #expect(ChatPresentation.runStatusLine(conversation.run!, steps: 0) == "Waiting for Mac · Step 1")
        #expect(ChatTranscript.stepCount(ChatConversation(id: "empty", title: "", revision: 0)) == 0)
    }

    @Test func `tool lines name the single step, the distinct tools, or the live step`() {
        let search = ChatToolCall(id: "s", function: .init(name: "web_search", arguments: #"{"query":"WWDC"}"#))
        let again = ChatToolCall(id: "s2", function: .init(name: "web_search", arguments: "{}"))
        let fetch = ChatToolCall(id: "f", function: .init(name: "web_fetch", arguments: "{}"))
        var steps = [search, again, fetch].map { ChatTranscript.Step(call: $0, result: nil, status: .done) }
        var activity = ChatTranscript.Activity(id: "a", messages: [], steps: steps, status: .done)
        #expect(ChatTranscript.activityTitle(activity) == "Search the web 2 · Read webpage")
        #expect(ChatTranscript.activityNote(activity) == "3 steps")
        #expect(ChatTranscript.failures(activity) == 0)
        #expect(ChatTranscript.activitySymbol(activity) == "magnifyingglass")
        activity.status = .running
        #expect(ChatTranscript.activityTitle(activity) == "Read webpage")
        #expect(ChatTranscript.activityNote(activity) == "Step 3")
        activity.status = .waiting
        #expect(ChatTranscript.activityTitle(activity) == "Waiting for Mac")
        #expect(ChatTranscript.activityNote(activity) == "Step 3")
        steps[2] = ChatTranscript.Step(call: fetch, result: nil, status: .failed)
        activity = ChatTranscript.Activity(id: "a", messages: [], steps: steps, status: .failed)
        #expect(ChatTranscript.activityTitle(activity) == "Search the web 2 · Read webpage")
        #expect(ChatTranscript.failures(activity) == 1)
        activity.status = .stopped
        #expect(ChatTranscript.activityNote(activity) == "Interrupted")
    }

    @Test func `a single step is named with its target and an empty live turn has a fallback`() {
        let search = ChatToolCall(id: "s", function: .init(name: "web_search", arguments: #"{"query":"WWDC"}"#))
        let one = ChatTranscript.Activity(id: "a", messages: [],
                                          steps: [.init(call: search, result: nil, status: .done)], status: .done)
        #expect(ChatTranscript.activityTitle(one) == "Search the web · WWDC")
        #expect(ChatTranscript.activityNote(one) == nil)
        #expect(ChatTranscript.activitySymbol(one) == "magnifyingglass")
        let empty = ChatTranscript.Activity(id: "b", messages: [], steps: [], status: .running)
        #expect(ChatTranscript.activityTitle(empty) == "Using tools")
        #expect(ChatTranscript.activityNote(empty) == "Step 1")
        #expect(ChatTranscript.activitySymbol(empty) == "list.bullet.clipboard")
    }

    @Test func `sidebar times show the clock for recent items and the date for older ones`() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 19, minute: 5)))
        let locale = Locale(identifier: "en_US_POSIX")
        var formatterCalendar = calendar
        formatterCalendar.locale = locale
        let today = now.addingTimeInterval(-60)
        let older = now.addingTimeInterval(-6 * 86400)
        let clock = ChatPresentation.historyTime(today, now: now, calendar: calendar, locale: locale)
        let date = ChatPresentation.historyTime(older, now: now, calendar: calendar, locale: locale)
        #expect(clock.contains(":"))
        #expect(!date.contains(":"))
        #expect(clock != date)
    }

    @Test func `model logos decode bundled artwork in both themes and cache images`() throws {
        for id in ["claude-sonnet", "gpt-5", "qwen3:8b", "kimi-k2", "glm-4.6"] {
            let descriptor = ModelIconResolver.resolve(modelID: id)
            for dark in [false, true] {
                let first = try #require(ChatModelLogo.image(for: descriptor, dark: dark))
                #expect(first.size.width > 0)
                #expect(ChatModelLogo.image(for: descriptor, dark: dark) === first)
            }
        }
        #expect(ChatModelLogo.image(for: .generic, dark: false) == nil)
        #expect(ChatModelLogo.image(for: .asset("missing", monochrome: false), dark: true) == nil)
    }

    @Test func `all bundled model logos decode on iOS and fallback views render`() throws {
        let first = try #require(ModelIconResolver.resolve(modelID: "claude").resourceURL(dark: false))
        let files = try FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(),
                                                                includingPropertiesForKeys: nil)
        let pngs = files.filter { $0.pathExtension == "png" }
        #expect(pngs.count == 172)
        for url in pngs {
            let key = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-light", with: "")
                .replacingOccurrences(of: "-dark", with: "")
            let image = try #require(ChatModelLogo.image(for: .asset(key, monochrome: false),
                                                        dark: url.lastPathComponent.contains("-dark")))
            #expect(image.cgImage != nil)
        }
        for dark in [false, true] {
            for id in ["claude", "gpt-5", "unknown"] {
                let renderer = ImageRenderer(content: ChatModelLogo(model: ChatModel(id: id, name: id))
                    .environment(\.colorScheme, dark ? .dark : .light))
                let image = try #require(renderer.uiImage)
                #expect(image.size.width == 28)
                #expect(image.size.height == 28)
            }
        }
    }
}
