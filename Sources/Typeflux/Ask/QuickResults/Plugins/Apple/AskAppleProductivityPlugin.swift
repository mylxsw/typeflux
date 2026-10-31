import Foundation

/// Only explicit Return writes to Apple's apps. Planning and typing remain local and read-free.
struct AskAppleProductivityPlugin: AskLauncherPlugin {
    enum Kind: String, Sendable { case notes, reminders }
    static let notesID = "appleNotes"
    static let remindersID = "appleReminders"
    static let keywords = [
        AskKeyword(keyword: "an", pluginID: notesID, aliases: ["applenotes", "备忘录", "備忘錄"]),
        AskKeyword(keyword: "remind", pluginID: remindersID, aliases: ["reminder", "提醒", "提醒事项", "提醒事項"])
    ]

    let kind: Kind
    var service: any AppleProductivityCreating = AppleProductivityService()
    var now: @Sendable () -> Date = { Date() }
    var calendar: Calendar = .current
    var id: String { kind == .notes ? Self.notesID : Self.remindersID }
    var title: String { L("apple.\(kind.rawValue).title") }
    var symbol: String { kind == .notes ? "note.text" : "checklist" }
    var defaultKeywords: [AskKeyword] { Self.keywords.filter { $0.pluginID == id } }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var preservesInputWhitespace: Bool { true }
    var entersOnReturn: Bool { true }
    var appURL: URL {
        URL(fileURLWithPath: "/System/Applications/\(kind == .notes ? "Notes" : "Reminders").app")
    }

    func placeholder(selectionLines _: Int?) -> String { L("apple.\(kind.rawValue).placeholder") }
    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? { nil }
    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? { nil }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let text = request.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .init(mode: .onSubmit, title: L("apple.open", title), actions: [openAction])
        }
        var plan = AskPluginPlan(mode: .onSubmit, title: L("apple.create", title))
        do {
            guard text.count <= 50000 else { throw AppleReminderDraft.Failure.invalid }
            let draft = kind == .reminders ? try AppleReminderDraft.parse(text, now: now(), calendar: calendar)
                : AppleReminderDraft(title: text.components(separatedBy: .newlines)[0], due: nil)
            plan.values["title"] = draft.title
            plan.values["body"] = kind == .notes ? text.components(separatedBy: "\n").dropFirst().joined(separator: "\n") : ""
            plan.title += " · " + String(draft.title.prefix(100))
            if let due = draft.due {
                plan.values["due"] = String(due.timeIntervalSince1970)
                plan.meta.append(.init(text: formatted(due, language: request.interfaceLanguage), emphasized: true))
            } else if kind == .reminders {
                plan.meta.append(.init(text: L("apple.noAlarm")))
            }
        } catch {
            plan.values["error"] = L(error as? AppleReminderDraft.Failure == .past ? "apple.past" : "apple.invalid")
            plan.title = plan.values["error"]!
        }
        return plan
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        if let error = plan.values["error"] { throw AskPluginFailure(message: error, retry: false) }
        guard let itemTitle = plan.values["title"], !itemTitle.isEmpty else { throw CancellationError() }
        let due = plan.values["due"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        if let due, due <= now() { throw AskPluginFailure(message: L("apple.past"), retry: false) }
        do {
            _ = try await service.create(kind: kind, title: itemTitle, body: plan.values["body"] ?? "", due: due)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A lost receipt can follow a successful write. Do not offer automatic retries.
            throw AskPluginFailure(message: L("apple.failed"), retry: false, actions: [openAction, settingsAction])
        }
        return .init(body: itemTitle, original: request.text, meta: plan.meta,
                     source: title, note: L("apple.saved"), actions: [openAction])
    }

    private var openAction: AskPluginAction {
        .init(kind: .open(appURL), title: L("apple.open", title), symbol: symbol, shortcut: .enter)
    }

    private var settingsAction: AskPluginAction {
        .init(kind: .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!),
              title: L("apple.permissions"), symbol: "lock.shield", shortcut: .commandO)
    }

    private func formatted(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
