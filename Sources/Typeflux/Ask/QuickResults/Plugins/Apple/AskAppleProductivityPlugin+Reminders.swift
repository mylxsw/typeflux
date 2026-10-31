import Foundation

extension AskAppleProductivityPlugin {
    static let confirmationOption = "apple.confirmReminder"

    private struct Confirmation: Codable {
        var input: String
        var timeZone: String
        var title: String
        var due: Double
    }

    func reminderPlan(_ text: String, request: AskPluginRequest) -> AskPluginPlan {
        var plan = AskPluginPlan(mode: .onSubmit, title: L("apple.create", title))
        guard text.count <= 50_000 else {
            plan.values["error"] = L("apple.tooLong")
            return plan
        }
        if let draft = confirmedReminder(request, text: text) {
            plan.values["title"] = draft.title
            plan.values["due"] = draft.due.map { String($0.timeIntervalSince1970) }
            plan.meta = reminderMeta(draft, language: request.interfaceLanguage)
            return plan
        }
        do {
            let draft = try AppleReminderDraft.parse(text, now: now(), calendar: calendar)
            if let due = draft.due {
                plan.values["title"] = draft.title
                plan.values["due"] = String(due.timeIntervalSince1970)
                plan.meta = reminderMeta(draft, language: request.interfaceLanguage)
                plan.title += " · " + String(draft.title.prefix(100))
                return plan
            }
        } catch AppleReminderDraft.Failure.past {
            plan.values["error"] = L("apple.past")
            return plan
        } catch {
            // Natural language is interpreted after submission, not rejected as invalid syntax.
        }
        plan.values["interpret"] = "true"
        plan.values["title"] = text
        plan.title = title
        return plan
    }

    func runReminder(_ request: AskPluginRequest, plan: AskPluginPlan) async throws -> AskPluginOutput {
        let text = Self.normalized(request.text)
        if plan.values["interpret"] != "true" {
            guard let itemTitle = plan.values["title"], !itemTitle.isEmpty else { throw CancellationError() }
            let due = plan.values["due"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            return try await createOutput(request, draft: .init(title: itemTitle, due: due), body: "", meta: plan.meta)
        }
        guard let generator else {
            throw AskPluginFailure(message: L("ask.plugin.prompt.noModel"), retry: false,
                                   actions: [.init(kind: .openSettings, title: L("ask.plugin.setting.title"), symbol: "gearshape", shortcut: .enter)])
        }
        let resolution: AppleReminderInterpreter.Resolution
        var contextCalendar = calendar
        contextCalendar.timeZone = calendar.timeZone
        let timeZone = contextCalendar.timeZone.identifier
        do {
            resolution = try await AppleReminderInterpreter(generator: generator).resolve(
                text, now: now(), calendar: contextCalendar, language: request.interfaceLanguage)
        } catch AppleReminderInterpreter.Failure.invalidResponse {
            throw AskPluginFailure(message: L("apple.reminders.understandFailed"))
        } catch AppleReminderDraft.Failure.past {
            throw AskPluginFailure(message: L("apple.past"), retry: false)
        }
        try Task.checkCancellation()
        guard calendar.timeZone.identifier == timeZone else {
            throw AskPluginFailure(message: L("apple.reminders.timeZoneChanged"))
        }
        switch resolution {
        case let .ready(draft):
            return try await createOutput(request, draft: draft, body: "",
                                          meta: reminderMeta(draft, language: request.interfaceLanguage))
        case let .suggested(draft):
            guard let due = draft.due, due > now() else { throw AskPluginFailure(message: L("apple.past"), retry: false) }
            let confirmation = Confirmation(input: text, timeZone: calendar.timeZone.identifier,
                                            title: draft.title, due: due.timeIntervalSince1970)
            let encoded = String(decoding: try JSONEncoder().encode(confirmation), as: UTF8.self)
            let action = AskPluginAction(kind: .rerun([Self.confirmationOption: encoded]),
                                         title: L("apple.reminders.confirm"), symbol: "plus.circle", shortcut: .enter)
            return .init(body: draft.title, original: request.text, meta: [], source: title,
                         note: nil, actions: [],
                         items: [.init(id: "apple.reminder.proposal", title: draft.title,
                                       subtitle: L("apple.reminders.suggestedTime", formatted(due, language: request.interfaceLanguage)),
                                       subtitleEmphasized: true, icon: .feature("apple-reminders"), actions: [action])])
        case let .clarify(question):
            return .init(body: question, original: request.text, meta: [], source: title,
                         note: L("apple.reminders.editInput"), actions: [])
        }
    }

    private func confirmedReminder(_ request: AskPluginRequest, text: String) -> AppleReminderDraft? {
        guard let raw = request.options[Self.confirmationOption], raw.utf8.count <= 512_000,
              let value = try? JSONDecoder().decode(Confirmation.self, from: Data(raw.utf8)),
              value.input == text, value.timeZone == calendar.timeZone.identifier,
              !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.title.count <= 50_000, value.due.isFinite else { return nil }
        return .init(title: value.title, due: Date(timeIntervalSince1970: value.due))
    }

    private func reminderMeta(_ draft: AppleReminderDraft, language: AppLanguage) -> [AskPluginMeta] {
        if let due = draft.due { return [.init(text: formatted(due, language: language), emphasized: true)] }
        return [.init(text: L("apple.noAlarm"))]
    }
}
