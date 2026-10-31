import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
struct AppleReminderInterpreterTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 31, hour: 12))! }
    private let input = "明天下午提醒我吃饭"

    private func request(_ text: String, options: [String: String] = [:]) -> AskPluginRequest {
        .init(text: text, origin: .argument, keyword: AskAppleProductivityPlugin.keywords[1],
              options: options, interfaceLanguage: .simplifiedChinese)
    }

    @Test func naturalLanguageIsSubmittedWithAnExplicitClockAndNoPlanningNetwork() async throws {
        let generator = ReminderTestGenerator(response: Self.payload("ready", title: "吃饭"))
        let service = ReminderTestService()
        let clock = now
        let plugin = AskAppleProductivityPlugin(kind: .reminders, service: service, generator: generator,
                                                now: { clock }, calendar: calendar)
        let req = request("明天下午三点提醒我吃饭")
        let plan = await plugin.plan(req)
        #expect(plan.values["error"] == nil && plan.values["interpret"] == "true")
        #expect(generator.prompts.isEmpty)
        #expect(await service.creations.isEmpty)
        let result = try await plugin.run(req, plan: plan, progress: { _ in })
        #expect(result.body == "吃饭" && result.note == L("apple.saved"))
        let created = try #require(await service.creations.first)
        #expect(created.title == "吃饭")
        #expect(calendar.component(.hour, from: try #require(created.due)) == 15)
        let context = try #require(generator.prompts.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        #expect(json["input"] as? String == req.text)
        #expect(json["currentInstant"] as? String == "2026-10-31T12:00:00+08:00")
        #expect(json["timeZone"] as? String == calendar.timeZone.identifier)
        #expect((json["calendarDates"] as? [String])?.contains("2026-11-02 Monday") == true)
    }

    @Test func productionGeneratorUsesStructuredOutputAndTheAskFeature() async throws {
        let service = ReminderJSONTestService(response: Self.payload("suggested", title: "吃饭"))
        let interpreter = AppleReminderInterpreter(generator: AskLLMTextGenerator(service: service))
        let result = try await interpreter.resolve(input, now: now, calendar: calendar, language: .simplifiedChinese)
        guard case let .suggested(draft) = result else { Issue.record("Missing suggested time"); return }
        #expect(draft.title == "吃饭")
        #expect(service.schemaName == "launcher_reminder" && service.feature == .askSelection)
    }

    @Test func vagueTimesAreConfirmedOnceWithoutAskingTheModelAgain() async throws {
        let generator = ReminderTestGenerator(response: Self.payload("suggested", title: "吃饭"))
        let service = ReminderTestService()
        let clock = now
        let plugin = AskAppleProductivityPlugin(kind: .reminders, service: service, generator: generator,
                                                now: { clock }, calendar: calendar)
        let req = request(input)
        let preview = try await plugin.run(req, plan: await plugin.plan(req), progress: { _ in })
        #expect(await service.creations.isEmpty)
        #expect(preview.selected?.title == "吃饭" && preview.selected?.subtitle.contains("15:00") == true)
        #expect(preview.selected?.subtitleEmphasized == true && preview.note == nil)
        guard case let .rerun(options) = try #require(preview.action(for: .enter)).kind else {
            Issue.record("Missing confirmation"); return
        }
        let confirmation = request(input, options: options)
        _ = try await plugin.run(confirmation, plan: await plugin.plan(confirmation), progress: { _ in })
        #expect(generator.prompts.count == 1)
        #expect(await service.creations.count == 1)
        let changed = request("明天下午提醒我散步", options: options)
        _ = try await plugin.run(changed, plan: await plugin.plan(changed), progress: { _ in })
        #expect(generator.prompts.count == 2)
        #expect(await service.creations.count == 1)
        var late = plugin
        late.now = { clock.addingTimeInterval(3 * 86400) }
        await #expect(throws: AskPluginFailure.self) {
            _ = try await late.run(confirmation, plan: await late.plan(confirmation), progress: { _ in })
        }
        #expect(await service.creations.count == 1)
    }

    @Test func untimedTasksAndClarificationsDoNotInventAlarms() async throws {
        let clock = now
        for (payload, expectedCount) in [
            (#"{"status":"untimed","title":"买牛奶","due":null}"#, 1),
            (#"{"status":"clarify","title":"","due":null,"question":"要提醒你做什么？"}"#, 0)
        ] {
            let service = ReminderTestService()
            let plugin = AskAppleProductivityPlugin(kind: .reminders, service: service,
                generator: ReminderTestGenerator(response: payload), now: { clock }, calendar: calendar)
            let req = request("提醒我买牛奶")
            let output = try await plugin.run(req, plan: await plugin.plan(req), progress: { _ in })
            #expect(await service.creations.count == expectedCount)
            #expect(await service.creations.first?.due == nil)
            if expectedCount == 0 { #expect(output.action(for: .enter) == nil && output.body == "要提醒你做什么？") }
        }
    }

    @Test(arguments: [
        #"{"status":"ready","title":"Task","due":null}"#,
        #"{"status":"suggested","title":"Task","due":null}"#,
        #"{"status":"untimed","title":"","due":null}"#,
        #"{"status":"untimed","title":"Task","due":{"year":2026,"month":11,"day":1,"hour":15,"minute":0}}"#,
        #"{"status":"ready","title":"Task","due":{"year":2027,"month":2,"day":30,"hour":15,"minute":0}}"#,
        #"{"status":"ready","title":"Task","due":{"year":2027,"month":2,"day":3,"hour":25,"minute":0}}"#,
        #"{"status":"clarify","title":"","due":null,"question":""}"#,
        #"{"status":"createNow","title":"Task","due":null}"#,
        "Not JSON"
    ])
    func invalidModelResponsesNeverBecomeUntimedTasks(_ response: String) {
        #expect(throws: AppleReminderInterpreter.Failure.self) {
            try AppleReminderInterpreter.decode(response, now: now, calendar: calendar)
        }
    }

    @Test func pastTimesDSTGapsFencesAndStreamLimitsAreHandled() async throws {
        let past = #"{"status":"ready","title":"Task","due":{"year":2026,"month":10,"day":31,"hour":9,"minute":0}}"#
        #expect(throws: AppleReminderDraft.Failure.self) {
            try AppleReminderInterpreter.decode(past, now: now, calendar: calendar)
        }
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let gap = #"{"status":"ready","title":"Task","due":{"year":2027,"month":3,"day":14,"hour":2,"minute":30}}"#
        #expect(throws: AppleReminderInterpreter.Failure.self) {
            try AppleReminderInterpreter.decode(gap, now: now, calendar: zone)
        }
        let fence = String(repeating: "\u{0060}", count: 3)
        let fenced = fence + "json\n" + Self.payload("ready", title: "吃饭") + "\n" + fence
        guard case .ready = try AppleReminderInterpreter.decode(fenced, now: now, calendar: calendar) else {
            Issue.record("Fenced JSON was not decoded"); return
        }
        let oversized = AppleReminderInterpreter(generator: ReminderTestGenerator(response: String(repeating: "x", count: 256001)))
        await #expect(throws: AppleReminderInterpreter.Failure.self) {
            try await oversized.resolve(input, now: now, calendar: calendar, language: .english)
        }
    }

    @MainActor @Test func cancelingInterpretationAndEditingConfirmationCannotWriteStaleTasks() async throws {
        let generator = ReminderTestGenerator(response: Self.payload("suggested", title: "吃饭"))
        let service = ReminderTestService(delay: .milliseconds(300))
        let clock = now
        let plugin = AskAppleProductivityPlugin(kind: .reminders, service: service, generator: generator,
                                                now: { clock }, calendar: calendar)
        let session = AskPluginSession(plugins: [plugin], keywords: { AskAppleProductivityPlugin.keywords })
        session.enter(AskAppleProductivityPlugin.keywords[1])
        session.update(text: input, selection: nil, language: .simplifiedChinese)
        try await wait { session.isPlanCurrent }
        #expect(session.run())
        try await wait { session.output?.selected?.id == "apple.reminder.proposal" }
        guard case let .rerun(options) = try #require(session.output?.action(for: .enter)).kind else {
            Issue.record("Missing confirmation"); return
        }
        session.rerun(with: options, selection: nil, text: input, language: .simplifiedChinese)
        try await wait { session.isRunning }
        session.update(text: "提醒我明天散步", selection: nil, language: .simplifiedChinese)
        try await wait { session.isPlanCurrent }
        #expect(session.request?.options[AskAppleProductivityPlugin.confirmationOption] == nil)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await service.creations.isEmpty)
        session.deactivate()
        let suspended = ReminderTestGenerator(response: nil)
        let pending = AskAppleProductivityPlugin(kind: .reminders, service: service, generator: suspended,
                                               now: { clock }, calendar: calendar)
        let req = request(input)
        let task = Task { try await pending.run(req, plan: await pending.plan(req), progress: { _ in }) }
        try await wait { !suspended.prompts.isEmpty }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled interpretation returned a result") }
        catch is CancellationError {}
        #expect(await service.creations.isEmpty)
    }

    @MainActor @Test func launcherUsesConfiguredAIAndConfirmationCreatesOnlyOneReminder() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let generator = ReminderTestGenerator(response: Self.payload("suggested", title: "吃饭"))
        let service = ReminderTestService(delay: .milliseconds(200))
        let clock = now, zone = calendar
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "remind " + input, foregroundControls: true, prepare: { model in
            model.promptAI = generator
            var plugins = model.makeLauncherPlugins()
            if let index = plugins.firstIndex(where: { $0.id == AskAppleProductivityPlugin.remindersID }),
               var reminder = plugins[index] as? AskAppleProductivityPlugin {
                #expect(reminder.generator != nil)
                reminder.service = service; reminder.now = { clock }; reminder.calendar = zone
                plugins[index] = reminder
            }
            model.plugins.replacePlugins(plugins)
        })
        defer { launcher.close() }
        try await wait { launcher.fixture.model.plugins.isPlanCurrent }
        #expect(generator.prompts.isEmpty)
        try await launcher.press(36)
        try await wait { launcher.fixture.model.plugins.output?.selected?.id == "apple.reminder.proposal" }
        #expect(await service.creations.isEmpty)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_REMINDER_AI_SNAPSHOT"],
           let host = launcher.window.contentView {
            try await Task.sleep(for: .milliseconds(50))
            if let height = launcher.heights.last { launcher.window.setContentSize(.init(width: AskMetrics.launcherWidth, height: height)) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        try await launcher.press(36)
        try await launcher.press(36)
        try await wait { launcher.fixture.model.plugins.output?.note == L("apple.saved") }
        #expect(generator.prompts.count == 1)
        #expect(await service.creations.count == 1)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    private static func payload(_ status: String, title: String) -> String {
        #"{"status":""# + status + #"","title":""# + title
            + #"","due":{"year":2026,"month":11,"day":1,"hour":15,"minute":0}}"#
    }
    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 600 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

final class ReminderTestGenerator: AskTextGenerating, @unchecked Sendable {
    private let response: String?
    private let lock = NSLock()
    private var recorded: [String] = []
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    init(response: String?) { self.response = response }
    func stream(systemPrompt _: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append(userPrompt); lock.unlock()
        return AsyncThrowingStream { continuation in
            if let response { continuation.yield(response); continuation.finish() }
        }
    }
}

private actor ReminderTestService: AppleProductivityCreating {
    struct Creation { var title: String; var due: Date? }
    var creations: [Creation] = []
    var delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func create(kind _: AskAppleProductivityPlugin.Kind, title: String, body _: String, due: Date?) async throws -> String {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        creations.append(.init(title: title, due: due))
        return "fixture-reminder"
    }
}

private final class ReminderJSONTestService: LLMService {
    private let response: String
    private(set) var schemaName: String?
    private(set) var feature: TypefluxCloudFeature?
    init(response: String) { self.response = response }
    func streamRewrite(request _: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AppleReminderInterpreter.Failure.invalidResponse) }
    }
    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        throw AppleReminderInterpreter.Failure.invalidResponse
    }
    func completeJSON(systemPrompt _: String, userPrompt _: String, schema: LLMJSONSchema) async throws -> String {
        schemaName = schema.name
        feature = LLMFeatureContext.feature
        return response
    }
}
