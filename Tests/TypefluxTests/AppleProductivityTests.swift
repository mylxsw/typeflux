import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
struct AppleProductivityTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))! }

    private func request(_ text: String, kind: AskAppleProductivityPlugin.Kind = .reminders) -> AskPluginRequest {
        .init(text: text, origin: .argument, keyword: AskAppleProductivityPlugin.keywords[kind == .notes ? 0 : 1],
              options: [:], interfaceLanguage: .english, selection: "Do not create from captured selection")
    }

    @Test func `relative absolute and local clock dates resolve before submission`() throws {
        for (text, day, hour, minute) in [
            ("明天 09:00 交报告", 1, 9, 0), ("tomorrow 09:00 Submit report", 1, 9, 0),
            ("后天 09:00 交报告", 2, 9, 0), ("2026-11-01 09:00 交报告", 1, 9, 0),
            ("09:00 交报告", 1, 9, 0), ("今天 13:30 交报告", 31, 13, 30),
            ("today 13:30 Submit report", 31, 13, 30), ("13:30 交报告", 31, 13, 30),
            ("30m 喝水", 31, 12, 30), ("30分钟后 喝水", 31, 12, 30),
            ("2H Review", 31, 14, 0), ("2小时后 检查", 31, 14, 0), ("1d 检查", 1, 12, 0)
        ] {
            let value = try AppleReminderDraft.parse(text, now: now, calendar: calendar)
            let due = try #require(value.due)
            let parts = calendar.dateComponents([.day, .hour, .minute], from: due)
            #expect(parts.day == day && parts.hour == hour && parts.minute == minute)
            #expect(!value.title.isEmpty)
        }
        #expect(try AppleReminderDraft.parse("Buy milk", now: now, calendar: calendar) == .init(title: "Buy milk", due: nil))
    }

    @Test(arguments: ["", " ", "明天上午9点 交报告", "明天 交报告", "tomorrow Task", "30m", "0m Task",
                      "99999999999999999999999m Task", "2026-02-30 09:00 Task", "2026-11-01 25:00 Task",
                      "2026-11-01 09:90 Task", "2026-10-30 09:00 Task", "今天 11:59 Task", "09:61 Task"])
    func `invalid and elapsed times do not become untimed tasks`(_ text: String) {
        #expect(throws: (any Error).self) { try AppleReminderDraft.parse(text, now: now, calendar: calendar) }
    }

    @Test func `DST gaps are rejected instead of moving an alarm silently`() {
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(throws: (any Error).self) {
            try AppleReminderDraft.parse("2027-03-14 02:30 Task", now: now, calendar: zone)
        }
    }

    @Test func `new defaults migrate once without claiming user keywords`() {
        let newIDs = [AskAppleProductivityPlugin.notesID, AskAppleProductivityPlugin.remindersID]
        let oldGroups = AskPluginRegistry.coveredGroups.filter { !newIDs.contains($0) }
        let saved = [AskKeyword(keyword: "an", pluginID: "custom"), AskKeyword(keyword: "old", pluginID: "custom")]
        let updated = AskPluginRegistry.keywords(saved: saved, known: oldGroups, reserved: ["remind"])
        #expect(updated.first?.pluginID == "custom")
        #expect(updated.first?.allKeywords == ["an", "old"])
        #expect(updated.first { $0.pluginID == newIDs[0] }?.keyword == "applenotes")
        #expect(updated.first { $0.pluginID == newIDs[1] }?.keyword == "reminder")
        #expect(AskPluginRegistry.keywords(saved: updated, known: AskPluginRegistry.coveredGroups) == updated)
        for word in ["备忘录", "備忘錄", "applenotes", "an", "提醒", "提醒事项", "reminder", "remind"] {
            #expect(AskKeywordMatcher.match(word + " Task", keywords: AskPluginRegistry.defaultKeywords) != nil)
        }
        #expect(AskKeywordKind(pluginID: newIDs[0]) == .appleNotes)
        #expect(AskKeywordKind(pluginID: newIDs[1]) == .appleReminders)
        for kind in [AskKeywordKind.appleNotes, .appleReminders] {
            let draft = AskKeywordDraft(adding: kind)
            #expect(draft.fieldProblem == nil && draft.result().pluginID == kind.pluginID)
        }
    }

    @Test func `planning never writes and empty inputs open the app`() async throws {
        let service = FakeAppleProductivityService()
        for kind in [AskAppleProductivityPlugin.Kind.notes, .reminders] {
            let plugin = AskAppleProductivityPlugin(kind: kind, service: service)
            #expect(!plugin.usesSelectionInput && plugin.preservesInputWhitespace && plugin.entersOnReturn)
            #expect(!plugin.placeholder(selectionLines: nil).isEmpty)
            #expect(plugin.nextOptions(after: .init(mode: .onSubmit, title: ""), request: request(""), step: 1) == nil)
            let empty = await plugin.plan(request("", kind: kind))
            #expect(empty.mode == .onSubmit && empty.action(for: .enter)?.kind == .open(plugin.appURL))
            let planned = await plugin.plan(request("Task", kind: kind))
            #expect(planned.mode == .onSubmit && planned.values["title"] == "Task")
        }
        #expect(await service.creations.isEmpty)
    }

    @Test func `notes retain text and reminder submission uses the preview date`() async throws {
        let service = FakeAppleProductivityService()
        let clock = now
        let notes = AskAppleProductivityPlugin(kind: .notes, service: service, now: { clock }, calendar: calendar)
        let input = request("Title\n  body <script> & \"quoted\"\nnext", kind: .notes)
        let plan = await notes.plan(input)
        let output = try await notes.run(input, plan: plan, progress: { _ in })
        #expect(output.body == "Title" && output.actions.count == 1 && output.action(for: .commandR) == nil)
        let reminders = AskAppleProductivityPlugin(kind: .reminders, service: service, now: { clock }, calendar: calendar)
        let reminderInput = request("30m Drink water")
        let reminderPlan = await reminders.plan(reminderInput)
        #expect(reminderPlan.meta.count == 1 && reminderPlan.meta[0].emphasized)
        _ = try await reminders.run(reminderInput, plan: reminderPlan, progress: { _ in })
        let untimedInput = request("Buy milk")
        let untimed = await reminders.plan(untimedInput)
        #expect(untimed.values["due"] == nil && untimed.meta.count == 1)
        _ = try await reminders.run(untimedInput, plan: untimed, progress: { _ in })
        let creations = await service.creations
        #expect(creations.count == 3)
        #expect(creations[0].body == "  body <script> & \"quoted\"\nnext")
        #expect(creations[1].title == "Drink water" && creations[1].due == clock.addingTimeInterval(1800))
        #expect(creations[2].due == nil)
    }

    @Test func `invalid oversized stale and failed requests offer no write retry`() async throws {
        let service = FakeAppleProductivityService()
        let clock = now
        let plugin = AskAppleProductivityPlugin(kind: .reminders, service: service, now: { clock }, calendar: calendar)
        for text in ["明天上午9点 Task", "今天 09:00 Task", String(repeating: "a", count: 50001)] {
            let input = request(text)
            let plan = await plugin.plan(input)
            do {
                _ = try await plugin.run(input, plan: plan, progress: { _ in })
                Issue.record("Invalid input was submitted")
            } catch let error as AskPluginFailure { #expect(!error.retry) }
        }
        let input = request("1m Task")
        let plan = await plugin.plan(input)
        var late = plugin
        late.now = { clock.addingTimeInterval(120) }
        do {
            _ = try await late.run(input, plan: plan, progress: { _ in })
            Issue.record("Elapsed preview was submitted")
        } catch let error as AskPluginFailure { #expect(!error.retry) }
        #expect(await service.creations.isEmpty)
        await service.setFailure(AppleProductivityService.Failure.noReceipt)
        do {
            _ = try await plugin.run(input, plan: plan, progress: { _ in })
            Issue.record("Missing receipt reported success")
        } catch let error as AskPluginFailure {
            #expect(!error.retry && error.actions.count == 2)
        }
        await service.setFailure(CancellationError())
        do {
            _ = try await plugin.run(input, plan: plan, progress: { _ in })
            Issue.record("Cancellation reported success")
        } catch is CancellationError {}
    }

    @Test func `service sends text as arguments and escapes note markup`() async throws {
        let runner = FakeAppleProductivityRunner()
        let service = AppleProductivityService(runner: runner)
        let title = "Title\" & do shell script \"touch /tmp/unwanted\""
        #expect(try await service.create(kind: .notes, title: title, body: "<tag>&\nbody", due: nil) == "test-id")
        let calls = runner.calls
        #expect(calls.count == 1 && calls[0].0 == "/usr/bin/osascript")
        let args = calls[0].1
        #expect(!args[1].contains(title) && args[2] == "--" && args[3] == title)
        #expect(args[4].contains("&lt;tag&gt;&amp;<br>body"))
        #expect(AppleProductivityService.html(title: "x", body: "") == "<div><b>x</b></div>")
        _ = try await service.create(kind: .reminders, title: "Task", body: "", due: now)
        #expect(runner.calls[1].1.count == 9)
        #expect(runner.calls[1].1[1].contains("remind me date:alarmDate"))
        #expect(runner.calls[1].1[1].contains("default list"))
        _ = try await service.create(kind: .reminders, title: "Untimed", body: "", due: nil)
        #expect(runner.calls[2].1.count == 5)
        runner.result = .init(stdout: "", stderr: "", exitCode: 0)
        await #expect(throws: AppleProductivityService.Failure.self) {
            try await service.create(kind: .notes, title: "x", body: "", due: nil)
        }
        runner.result = .init(stdout: "not-an-id", stderr: "Denied", exitCode: 1)
        await #expect(throws: AppleProductivityService.Failure.self) {
            try await service.create(kind: .reminders, title: "x", body: "", due: nil)
        }
    }

    @MainActor @Test func `launcher requires submission and repeated Return never creates twice`() async throws {
        let service = FakeAppleProductivityService()
        let clock = now
        let plugin = AskAppleProductivityPlugin(kind: .reminders, service: service, now: { clock }, calendar: calendar)
        let session = AskPluginSession(plugins: [plugin], keywords: { AskAppleProductivityPlugin.keywords })
        let keyword = AskAppleProductivityPlugin.keywords[1]
        session.enter(keyword)
        session.update(text: "30m Drink water", selection: nil, language: .english)
        for _ in 0 ..< 200 {
            if case .ready = session.phase { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.creations.isEmpty)
        #expect(session.run())
        #expect(!session.run())
        for _ in 0 ..< 200 where session.output == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.output?.body == "Drink water")
        #expect(!session.run())
        #expect(await service.creations.count == 1)
        session.deactivate()
    }
}

private actor FakeAppleProductivityService: AppleProductivityCreating {
    struct Creation { var title: String; var body: String; var due: Date? }
    var creations: [Creation] = []
    var failure: (any Error)?
    func setFailure(_ error: any Error) { failure = error }
    func create(kind _: AskAppleProductivityPlugin.Kind, title: String, body: String, due: Date?) throws -> String {
        if let failure { throw failure }
        creations.append(.init(title: title, body: body, due: due))
        return "test-id"
    }
}

private final class FakeAppleProductivityRunner: ProcessCommandRunning {
    var calls: [(String, [String])] = []
    var result = ProcessCommandResult(stdout: "test-id\n", stderr: "", exitCode: 0)
    func run(executablePath: String, arguments: [String], environment _: [String: String]?,
             currentDirectoryURL _: URL?) async throws -> ProcessCommandResult {
        calls.append((executablePath, arguments))
        return result
    }
}
