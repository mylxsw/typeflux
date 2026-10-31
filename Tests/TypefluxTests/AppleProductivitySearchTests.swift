import AppKit
import Foundation
import EventKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
struct AppleProductivitySearchTests {
    private func request(_ text: String = "", options: [String: String] = [:],
                         kind: AskAppleProductivityPlugin.Kind = .notes) -> AskPluginRequest {
        .init(text: text, origin: .argument, keyword: AskAppleProductivitySearchPlugin.keywords[kind == .notes ? 0 : 1],
              options: options, interfaceLanguage: .english, selection: "Never forward captured text")
    }

    @Test func `search keywords migrate independently and preserve creation and conflicts`() {
        let ids = [AskAppleProductivitySearchPlugin.notesID, AskAppleProductivitySearchPlugin.remindersID]
        let oldGroups = AskPluginRegistry.coveredGroups.filter { !ids.contains($0) }
        let saved = AskAppleProductivityPlugin.keywords
        let migrated = AskPluginRegistry.keywords(saved: saved, known: oldGroups)
        #expect(migrated.prefix(2).map(\.pluginID) == saved.map(\.pluginID))
        #expect(migrated.suffix(2).map(\.keyword) == ["notes", "reminders"])
        #expect(AskPluginRegistry.keywords(saved: migrated, known: AskPluginRegistry.coveredGroups) == migrated)
        let reserved = AskPluginRegistry.keywords(saved: saved, known: oldGroups, reserved: ["notes", "reminders"])
        #expect(!reserved.contains { $0.contains("notes") || $0.contains("reminders") })
        let owner = AskKeyword(keyword: "notes", pluginID: "custom")
        #expect(AskPluginRegistry.keywords(saved: saved + [owner], known: oldGroups).contains(owner))
        for keyword in AskAppleProductivitySearchPlugin.keywords {
            let kind = AskKeywordKind(pluginID: keyword.pluginID)
            #expect(kind == (keyword.keyword == "notes" ? .appleNotesSearch : .appleRemindersSearch))
            #expect(AskKeywordDraft(editing: keyword).result() == keyword)
            #expect(AskKeywordListPresentation.name(of: keyword).contains("Search"))
            for word in keyword.allKeywords {
                #expect(AskKeywordMatcher.match(word + " query", keywords: [keyword]) == .active(keyword, argument: "query"))
            }
        }
    }

    @Test func `list searches typed text and separates scope from captured selection`() async throws {
        let service = FakeAppleBrowser()
        let plugin = AskAppleProductivitySearchPlugin(kind: .reminders, service: service)
        let input = request("  report  ", kind: .reminders)
        let plan = await plugin.plan(input)
        #expect(plan.mode == .live && plan.debounce == .milliseconds(400))
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        #expect(!plugin.placeholder(selectionLines: 3).isEmpty && plugin.optionName != nil)
        let output = try await plugin.run(input, plan: plan, progress: { _ in })
        #expect(output.items.count == 1 && output.items[0].title == "Report")
        #expect(output.items[0].subtitle.contains("Pending"))
        #expect(await service.queries.first?.0 == "report")
        #expect(await service.queries.first?.1 == false)
        let options = try #require(plugin.nextOptions(after: plan, request: input, step: 1))
        #expect(options[AskAppleProductivitySearchPlugin.completedOption] == "true")
        _ = try await plugin.run(request("", options: options, kind: .reminders), plan: plan, progress: { _ in })
        #expect(await service.queries.last?.1 == true)
        #expect(AskAppleProductivitySearchPlugin(kind: .notes).optionName == nil)
    }

    @Test func `preview stays local and opens only when explicitly requested`() async throws {
        let service = FakeAppleBrowser()
        let plugin = AskAppleProductivitySearchPlugin(kind: .notes, service: service)
        let input = request("report", options: [AskAppleProductivitySearchPlugin.readOption: "fixture-id"])
        let plan = await plugin.plan(input)
        #expect(plan.mode == .onSubmit)
        let output = try await plugin.run(input, plan: plan, progress: { _ in })
        #expect(output.body.contains("Full fixture body") && output.items.isEmpty && !output.dismisses)
        #expect(output.action(for: .commandR)?.kind == AskAppleProductivitySearchPlugin.backAction().kind)
        #expect(output.action(for: .commandC)?.kind == .copy("Full fixture body"))
        #expect(await service.opened.isEmpty)
        let opening = request(options: [AskAppleProductivitySearchPlugin.openOption: "fixture-id"])
        let opened = try await plugin.run(opening, plan: await plugin.plan(opening), progress: { _ in })
        #expect(opened.dismisses)
        #expect(await service.opened == ["fixture-id"])
    }

    @Test func `locked truncated overdue and completed previews explain their state`() async throws {
        let service = FakeAppleBrowser()
        var item = FakeAppleBrowser.item
        item.locked = true; item.body = ""; item.truncated = true
        await service.setItem(item)
        let notes = AskAppleProductivitySearchPlugin(kind: .notes, service: service)
        let input = request(options: [AskAppleProductivitySearchPlugin.readOption: item.id])
        let output = try await notes.run(input, plan: await notes.plan(input), progress: { _ in })
        #expect(output.body.contains(L("apple.search.locked")) && output.note == L("apple.search.truncated"))
        item.locked = false; item.completed = true
        item.due = Date(timeIntervalSince1970: 1); item.alarm = item.due
        await service.setItem(item)
        let reminders = AskAppleProductivitySearchPlugin(kind: .reminders, service: service)
        let completed = try await reminders.run(request(kind: .reminders), plan: await reminders.plan(input), progress: { _ in })
        #expect(completed.items[0].subtitle.contains(L("apple.search.completed")))
        #expect(completed.items[0].subtitle.contains("Due:") && completed.items[0].subtitle.contains("Alarm:"))
        item.completed = false; await service.setItem(item)
        let overdue = try await reminders.run(request(kind: .reminders), plan: await reminders.plan(input), progress: { _ in })
        #expect(overdue.items[0].subtitle.contains(L("apple.search.overdue")))
    }

    @Test func `empty limited and unavailable searches remain distinguishable`() async throws {
        let service = FakeAppleBrowser()
        let plugin = AskAppleProductivitySearchPlugin(kind: .notes, service: service)
        let input = request()
        let plan = await plugin.plan(input)
        await service.setMatches(.init(items: [], total: 0, hasMore: false))
        let empty = try await plugin.run(input, plan: plan, progress: { _ in })
        #expect(empty.selected == nil && empty.items[0].title == L("apple.search.empty"))
        await service.setMatches(.init(items: [FakeAppleBrowser.item], total: 50, hasMore: true))
        #expect(try await plugin.run(input, plan: plan, progress: { _ in }).note == L("apple.search.more", 1, 50))
        for error in [AppleProductivityBrowser.Failure.missing, .changed] {
            await service.setFailure(error)
            do {
                _ = try await plugin.run(input, plan: plan, progress: { _ in })
                Issue.record("Read failure was shown as an empty list")
            } catch let failure as AskPluginFailure {
                #expect(failure.actions.count == 2 && failure.retry)
            }
        }
        await service.setFailure(nil)
        do {
            _ = try await plugin.run(request(String(repeating: "x", count: 501)), plan: plan, progress: { _ in })
            Issue.record("Overlong query reached the app")
        } catch let failure as AskPluginFailure { #expect(failure.message == L("apple.search.tooLong")) }
        await service.setFailure(CancellationError())
        await #expect(throws: CancellationError.self) { try await plugin.run(input, plan: plan, progress: { _ in }) }
    }

    @Test func `browser serializes arguments and rejects stale or malformed receipts`() async throws {
        let runner = FakeAppleBrowseRunner()
        let browser = AppleProductivityBrowser(runner: runner)
        let query = "quotes\"\n\\'); do shell script \"bad\""
        let item = FakeAppleBrowser.item
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try #require(String(data: encoder.encode(item.withoutBody), encoding: .utf8))
        runner.body = "{\"items\":[\(encoded)],\"total\":1,\"hasMore\":false}"
        #expect(try await browser.search(kind: .notes, query: query, includeCompleted: true).items == [item.withoutBody])
        #expect(runner.calls[0].suffix(4) == ["search", "notes", query, "true"])
        #expect(!runner.calls[0][3].contains(query))
        runner.body = "{\"item\":\(try #require(String(data: encoder.encode(item), encoding: .utf8)))}"
        #expect(try await browser.read(kind: .notes, id: item.id) == item)
        #expect(runner.calls[1].suffix(4) == ["read", "notes", item.id, "false"])
        runner.body = "{\"opened\":true}"
        try await browser.open(kind: .notes, id: item.id)
        #expect(runner.calls[2].suffix(4) == ["open", "notes", item.id, "false"])
        for body in ["{}", "{\"error\":\"missing\"}", "{\"error\":\"changed\"}",
                     "{\"items\":[],\"total\":10,\"hasMore\":false}"] {
            runner.body = body
            await #expect(throws: (any Error).self) { try await browser.search(kind: .notes, query: "", includeCompleted: false) }
        }
        runner.body = "{\"item\":\(encoded.replacingOccurrences(of: "fixture-id", with: "other-id"))}"
        await #expect(throws: AppleProductivityBrowser.Failure.self) { try await browser.read(kind: .notes, id: item.id) }
        await #expect(throws: AppleProductivityBrowser.Failure.self) { try await browser.read(kind: .notes, id: "") }
        await #expect(throws: AppleProductivityBrowser.Failure.self) {
            try await browser.search(kind: .notes, query: String(repeating: "x", count: 501), includeCompleted: false)
        }
    }

    @Test func `reminder access is requested only by the explicit authorization action`() async throws {
        let service = FakeAppleBrowser()
        await service.setFailure(EventKitReminderBrowser.Failure.permissionRequired)
        let plugin = AskAppleProductivitySearchPlugin(kind: .reminders, service: service)
        let input = request(kind: .reminders)
        let plan = await plugin.plan(input)
        var authorization: AskPluginAction?
        do {
            _ = try await plugin.run(input, plan: plan, progress: { _ in })
            Issue.record("Unapproved reminder access was attempted")
        } catch let failure as AskPluginFailure {
            #expect(!failure.retry)
            authorization = failure.action(for: .enter)
        }
        #expect(await service.accessRequests == 0)
        guard case let .rerun(options) = try #require(authorization).kind else { Issue.record("Missing authorization action"); return }
        _ = try await plugin.run(request(options: options, kind: .reminders), plan: plan, progress: { _ in })
        #expect(await service.accessRequests == 1)
        await service.setFailure(EventKitReminderBrowser.Failure.permissionDenied)
        do {
            _ = try await plugin.run(input, plan: plan, progress: { _ in })
            Issue.record("Denied reminder access was ignored")
        } catch let failure as AskPluginFailure {
            #expect(!failure.retry)
            guard case let .open(url)? = failure.action(for: .enter)?.kind else { Issue.record("Missing privacy settings action"); return }
            #expect(url.absoluteString.contains("Privacy_Reminders"))
        }
    }

    @Test func `native reminders match the full body then return bounded snapshots and correct dates`() {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "Work"
        let pending = EKReminder(eventStore: store)
        pending.title = "Report"; pending.calendar = calendar
        pending.notes = String(repeating: "x", count: 50001) + " Needle"
        var due = DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 0)
        due.calendar = Calendar(identifier: .gregorian)
        pending.dueDateComponents = due
        pending.addAlarm(EKAlarm(relativeOffset: -300))
        let completed = EKReminder(eventStore: store)
        completed.title = "Finished"; completed.notes = "Needle"; completed.calendar = calendar; completed.isCompleted = true
        let matches = EventKitReminderBrowser.matches([pending, completed], query: "needle", includeCompleted: false)
        #expect(matches.total == 1 && matches.items[0].body.isEmpty)
        #expect(EventKitReminderBrowser.matches([pending, completed], query: "Needle", includeCompleted: true).total == 2)
        let preview = EventKitReminderBrowser.snapshot(pending, includeBody: true)
        #expect(preview.body.count == 50000 && preview.truncated && preview.container == "Work")
        #expect(preview.alarm == preview.due?.addingTimeInterval(-300) && preview.allDay == false)
        due.hour = nil; due.minute = nil; pending.dueDateComponents = due
        #expect(EventKitReminderBrowser.snapshot(pending, includeBody: false).allDay == true)
        let reminders = (0 ..< 35).map { index -> EKReminder in
            let item = EKReminder(eventStore: store); item.title = "Item \(index)"; return item
        }
        let limited = EventKitReminderBrowser.matches(reminders, query: "", includeCompleted: true)
        #expect(limited.items.count == 30 && limited.total == 35 && limited.hasMore)
    }

    @MainActor @Test func `launcher previews returns edits and opens without sending to AI`() async throws {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let service = FakeAppleBrowser()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "notes ", prepare: { model in
            var plugins = model.makeLauncherPlugins().filter { $0.id != AskAppleProductivitySearchPlugin.notesID }
            plugins.append(AskAppleProductivitySearchPlugin(kind: .notes, service: service))
            model.plugins.replacePlugins(plugins)
        })
        defer { launcher.close() }
        try await settle { launcher.fixture.model.plugins.output?.items.first?.id == "fixture-id" }
        #expect(launcher.fixture.model.plugins.keyword?.pluginID == AskAppleProductivitySearchPlugin.notesID)
        try snapshot(launcher, name: "list")
        try await launcher.press(36)
        try await settle { launcher.fixture.model.plugins.output?.body.contains("Full fixture body") == true }
        #expect(launcher.dismissed == 0)
        #expect(await service.opened.isEmpty)
        try await launcher.press(53)
        try await settle { launcher.fixture.model.plugins.output?.items.first?.id == "fixture-id" }
        #expect(launcher.dismissed == 0)
        try await launcher.press(36)
        try await settle { launcher.fixture.model.plugins.output?.items.isEmpty == true }
        #expect(!AskComposer(model: launcher.fixture.model, launcher: true).launcherCanOpenFeatureWindow)
        try snapshot(launcher, name: "preview")
        launcher.editor.selectAll(nil)
        launcher.editor.insertText("other", replacementRange: NSRange(location: NSNotFound, length: 0))
        launcher.fixture.model.launcherDraft.text = "other"
        #expect(launcher.fixture.model.plugins.request?.text != "other")
        try await launcher.press(31, .command)
        #expect(await service.opened.isEmpty)
        try await settle { launcher.fixture.model.plugins.output?.items.first?.id == "fixture-id"
            && launcher.fixture.model.plugins.request?.text == "other" && launcher.fixture.model.plugins.isPlanCurrent }
        #expect(!AskAppleProductivitySearchPlugin.isPreview(launcher.fixture.model.plugins.request?.options ?? [:]))
        try await launcher.press(31, .command)
        try await settle { launcher.dismissed == 1 }
        #expect(await service.opened == ["fixture-id"])
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @MainActor private func settle(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @MainActor @Test func `reminder launcher authorizes switches scope and opens the preview`() async throws {
        let service = FakeAppleBrowser()
        await service.setFailure(EventKitReminderBrowser.Failure.permissionRequired)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "reminders ", prepare: { model in
            var plugins = model.makeLauncherPlugins().filter { $0.id != AskAppleProductivitySearchPlugin.remindersID }
            plugins.append(AskAppleProductivitySearchPlugin(kind: .reminders, service: service))
            model.plugins.replacePlugins(plugins)
        })
        defer { launcher.close() }
        try await settle { launcher.fixture.model.plugins.failure != nil }
        #expect(await service.accessRequests == 0)
        try snapshot(launcher, name: "permission")
        try await launcher.press(36)
        try await settle { launcher.fixture.model.plugins.output?.selected?.id == "fixture-id" }
        #expect(await service.accessRequests == 1)
        try await launcher.press(48)
        try await settle { launcher.fixture.model.plugins.output?.note == L("apple.search.all") }
        #expect(await service.queries.last?.1 == true)
        try await launcher.press(36)
        try await settle { launcher.fixture.model.plugins.output?.body.contains("Full fixture body") == true }
        #expect(!AskComposer(model: launcher.fixture.model, launcher: true).launcherCanOpenFeatureWindow)
        try await launcher.press(31, .command)
        try await settle { launcher.dismissed == 1 }
        #expect(await service.opened == ["fixture-id"])
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @MainActor private func snapshot(_ launcher: AskQuickResultsInteractionTests.Launcher, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_APPLE_BROWSE_SNAPSHOTS"],
              let host = launcher.window.contentView else { return }
        if let height = launcher.heights.last { launcher.window.setContentSize(.init(width: AskMetrics.launcherWidth, height: height)) }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }
}

private actor FakeAppleBrowser: AppleProductivityBrowsing {
    static let item = AppleProductivityItem(id: "fixture-id", title: "Report", container: "Work", modified: nil,
                                            due: nil, alarm: nil, completed: false, locked: false,
                                            body: "Full fixture body", truncated: false)
    var current = FakeAppleBrowser.item
    var matches: AppleProductivityMatches?
    var queries: [(String, Bool)] = []
    var opened: [String] = []
    var failure: (any Error)?
    var accessRequests = 0
    func setItem(_ item: AppleProductivityItem) { current = item }
    func setMatches(_ value: AppleProductivityMatches) { matches = value }
    func setFailure(_ error: (any Error)?) { failure = error }
    func requestAccess(kind _: AskAppleProductivityPlugin.Kind) {
        accessRequests += 1
        if let value = failure as? EventKitReminderBrowser.Failure, case .permissionRequired = value { failure = nil }
    }
    func search(kind _: AskAppleProductivityPlugin.Kind, query: String, includeCompleted: Bool) throws -> AppleProductivityMatches {
        if let failure { throw failure }
        queries.append((query, includeCompleted))
        return matches ?? .init(items: [current], total: 1, hasMore: false)
    }
    func read(kind _: AskAppleProductivityPlugin.Kind, id _: String) throws -> AppleProductivityItem {
        if let failure { throw failure }; return current
    }
    func open(kind _: AskAppleProductivityPlugin.Kind, id: String) throws {
        if let failure { throw failure }; opened.append(id)
    }
}

private extension AppleProductivityItem {
    var withoutBody: Self { var item = self; item.body = ""; return item }
}

private final class FakeAppleBrowseRunner: ProcessCommandRunning {
    var body = "{}"
    var calls: [[String]] = []
    func run(executablePath: String, arguments: [String], environment _: [String: String]?,
             currentDirectoryURL _: URL?) async throws -> ProcessCommandResult {
        #expect(executablePath == "/usr/bin/osascript")
        calls.append(arguments)
        return .init(stdout: body, stderr: "", exitCode: 0)
    }
}
