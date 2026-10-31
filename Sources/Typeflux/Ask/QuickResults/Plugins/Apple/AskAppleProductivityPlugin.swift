import Foundation

/// Planning remains local. Submitted natural reminders use AI; only explicit actions write to Apple's apps.
struct AskAppleProductivityPlugin: AskLauncherPlugin {
    enum Kind: String, Sendable { case notes, reminders }
    static let notesID = "appleNotes"
    static let remindersID = "appleReminders"
    static let keywords = [
        AskKeyword(keyword: "note", pluginID: notesID, aliases: ["an", "applenotes", "备忘录", "備忘錄"]),
        AskKeyword(keyword: "remind", pluginID: remindersID, aliases: ["reminder", "提醒", "提醒事项", "提醒事項"])
    ]

    /// Promote the previous default once, retaining aliases and user-owned keyword names.
    static func migratingNoteKeyword(_ keywords: [AskKeyword], reserved: Set<String>) -> [AskKeyword] {
        guard !reserved.contains("note"),
              let index = keywords.firstIndex(where: { $0.pluginID == notesID && $0.keyword.lowercased() == "an" })
                ?? keywords.firstIndex(where: { $0.pluginID == notesID }),
              !keywords.enumerated().contains(where: { $0.offset != index && $0.element.contains("note") })
        else { return keywords }
        var result = keywords
        if result[index].keyword.lowercased() == "an" {
            let previous = result[index].keyword
            result[index].keyword = "note"
            result[index].aliases.removeAll { $0.caseInsensitiveCompare("note") == .orderedSame }
            result[index].aliases.insert(previous, at: 0)
        } else if !result[index].contains("note") {
            result[index].aliases.append("note")
        }
        return result
    }

    let kind: Kind
    var service: any AppleProductivityCreating = AppleProductivityService()
    var generator: (any AskTextGenerating)?
    var now: @Sendable () -> Date = { Date() }
    var calendar: Calendar = .autoupdatingCurrent
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
        let text = Self.normalized(request.text)
        guard !text.isEmpty else {
            return .init(mode: .onSubmit, title: L("apple.open", title), actions: [openAction])
        }
        if kind == .reminders { return reminderPlan(text, request: request) }
        var plan = AskPluginPlan(mode: .onSubmit, title: L("apple.create", title))
        guard text.count <= 50000 else {
            plan.values["error"] = L("apple.tooLong")
            return plan
        }
        let lines = text.components(separatedBy: "\n")
        plan.values["title"] = lines[0]
        plan.values["body"] = lines.dropFirst().joined(separator: "\n")
        plan.title += " · " + String(lines[0].prefix(100))
        return plan
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        if let error = plan.values["error"] { throw AskPluginFailure(message: error, retry: false) }
        if kind == .reminders { return try await runReminder(request, plan: plan) }
        guard let itemTitle = plan.values["title"], !itemTitle.isEmpty else { throw CancellationError() }
        let due = plan.values["due"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return try await createOutput(request, draft: .init(title: itemTitle, due: due),
                                      body: plan.values["body"] ?? "", meta: plan.meta)
    }

    func createOutput(_ request: AskPluginRequest, draft: AppleReminderDraft, body: String,
                      meta: [AskPluginMeta]) async throws -> AskPluginOutput {
        try Task.checkCancellation()
        let itemTitle = draft.title, due = draft.due
        if let due, due <= now() { throw AskPluginFailure(message: L("apple.past"), retry: false) }
        do {
            _ = try await service.create(kind: kind, title: itemTitle, body: body, due: due)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A lost receipt can follow a successful write. Do not offer automatic retries.
            throw AskPluginFailure(message: L("apple.failed"), retry: false, actions: [openAction, settingsAction])
        }
        return .init(body: itemTitle, original: request.text, meta: meta,
                     source: title, note: L("apple.saved"), actions: [openAction])
    }

    private var openAction: AskPluginAction {
        .init(kind: .open(appURL), title: L("apple.open", title), symbol: symbol, shortcut: .enter)
    }

    private var settingsAction: AskPluginAction {
        .init(kind: .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!),
              title: L("apple.permissions"), symbol: "lock.shield", shortcut: .commandO)
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func formatted(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
