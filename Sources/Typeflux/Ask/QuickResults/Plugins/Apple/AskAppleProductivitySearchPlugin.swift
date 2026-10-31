import Foundation

/// Browses existing items; only the explicit open action changes application focus.
struct AskAppleProductivitySearchPlugin: AskLauncherPlugin {
    static let notesID = "appleNotesSearch"
    static let remindersID = "appleRemindersSearch"
    static let readOption = "apple.readID"
    static let openOption = "apple.openID"
    static let completedOption = "apple.includeCompleted"
    static let accessOption = "apple.requestReminderAccess"
    static let keywords = [
        AskKeyword(keyword: "notes", pluginID: notesID, aliases: ["搜备忘录", "搜索备忘录", "搜尋備忘錄"]),
        AskKeyword(keyword: "reminders", pluginID: remindersID, aliases: ["搜提醒", "搜索提醒事项", "搜尋提醒事項"])
    ]

    let kind: AskAppleProductivityPlugin.Kind
    var service: any AppleProductivityBrowsing
    var now: @Sendable () -> Date
    init(kind: AskAppleProductivityPlugin.Kind, service: (any AppleProductivityBrowsing)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.kind = kind
        if let service { self.service = service }
        else if kind == .notes { self.service = AppleProductivityBrowser() }
        else { self.service = EventKitReminderBrowser() }
        self.now = now
    }
    var id: String { kind == .notes ? Self.notesID : Self.remindersID }
    var title: String { L("apple.\(kind.rawValue).searchTitle") }
    var symbol: String { kind == .notes ? "note.text" : "checklist" }
    var defaultKeywords: [AskKeyword] { Self.keywords.filter { $0.pluginID == id } }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }
    var optionName: String? { kind == .reminders ? L("apple.search.scope") : nil }

    func placeholder(selectionLines _: Int?) -> String { L("apple.\(kind.rawValue).searchPlaceholder") }
    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? { nil }

    static func isPreview(_ options: [String: String]) -> Bool {
        options[readOption]?.isEmpty == false || options[openOption]?.isEmpty == false
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        .init(mode: Self.isPreview(request.options) ? .onSubmit : .live, title: title,
              debounce: .milliseconds(400))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        do {
            if request.options[Self.accessOption] == "true" { try await service.requestAccess(kind: kind) }
            if let id = request.options[Self.openOption], !id.isEmpty {
                try await service.open(kind: kind, id: id)
                return .init(body: "", original: request.text, meta: [], source: title, actions: [], dismisses: true)
            }
            if let id = request.options[Self.readOption], !id.isEmpty {
                return preview(try await service.read(kind: kind, id: id), request: request)
            }
            let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count <= 500 else { throw AppleProductivityBrowser.Failure.invalid }
            let matches = try await service.search(kind: kind, query: query,
                                                   includeCompleted: request.options[Self.completedOption] == "true")
            try Task.checkCancellation()
            var items = matches.items.map { item in
                AskPluginItem(id: item.id, title: item.title, subtitle: subtitle(item, language: request.interfaceLanguage),
                              icon: .feature(kind == .notes ? "apple-notes" : "apple-reminders"),
                              actions: [
                                  .init(kind: .rerun([Self.readOption: item.id, Self.openOption: ""]),
                                        title: L("apple.search.preview"), symbol: "doc.text.magnifyingglass", shortcut: .enter),
                                  openAction(item.id, shortcut: .commandO)
                              ])
            }
            if items.isEmpty {
                items = [.init(id: "apple.search.empty", title: L(query.isEmpty ? "apple.search.empty" : "apple.search.noMatch"),
                               icon: .symbol(symbol), valid: false)]
            }
            var summary: [String] = kind == .reminders ? [L(request.options[Self.completedOption] == "true"
                ? "apple.search.all" : "apple.search.pending")] : []
            if matches.hasMore { summary.append(L("apple.search.more", matches.items.count, matches.total)) }
            return .init(body: matches.items.map(\.title).joined(separator: "\n"), original: query,
                         meta: kind == .reminders ? [.init(text: L(request.options[Self.completedOption] == "true"
                             ? "apple.search.all" : "apple.search.pending"))] : [],
                         source: title, note: summary.isEmpty ? nil : summary.joined(separator: " · "),
                         actions: [Self.backAction(title: L("apple.search.refresh"))], items: items)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if case EventKitReminderBrowser.Failure.permissionRequired = error {
                throw AskPluginFailure(message: L("apple.search.accessRequired"), retry: false, actions: [
                    .init(kind: .rerun([Self.accessOption: "true"]), title: L("apple.search.authorize"),
                          symbol: "lock.open", shortcut: .enter)
                ])
            }
            if case EventKitReminderBrowser.Failure.permissionDenied = error {
                throw AskPluginFailure(message: L("apple.search.accessDenied"), retry: false,
                                       actions: [settingsAction.with(shortcut: .enter)])
            }
            let key: String
            switch error {
            case AppleProductivityBrowser.Failure.missing: key = "apple.search.missing"
            case AppleProductivityBrowser.Failure.changed: key = "apple.search.changed"
            case AppleProductivityBrowser.Failure.invalid where request.text.count > 500: key = "apple.search.tooLong"
            default: key = kind == .reminders ? "apple.reminders.searchFailed" : "apple.search.failed"
            }
            throw AskPluginFailure(message: L(key), actions: [Self.backAction(), settingsAction])
        }
    }

    func nextOptions(after _: AskPluginPlan, request: AskPluginRequest, step _: Int) -> [String: String]? {
        guard kind == .reminders else { return nil }
        return [Self.completedOption: request.options[Self.completedOption] == "true" ? "false" : "true",
                Self.readOption: "", Self.openOption: ""]
    }

    static func backAction(title: String? = nil) -> AskPluginAction {
        .init(kind: .rerun([readOption: "", openOption: ""]), title: title ?? L("apple.search.back"),
              symbol: "arrow.left", shortcut: .commandR)
    }

    private func preview(_ item: AppleProductivityItem, request: AskPluginRequest) -> AskPluginOutput {
        let body = item.locked ? item.title + "\n\n" + L("apple.search.locked")
            : item.body.isEmpty ? item.title : kind == .notes ? item.body : item.title + "\n\n" + item.body
        var detail = item.locked ? L("apple.search.locked") : item.body
        if kind == .notes, detail.components(separatedBy: .newlines).first == item.title {
            detail = String(detail.dropFirst(item.title.count)).trimmingCharacters(in: .newlines)
        }
        let displayed = item.title + "\n" + subtitle(item, language: request.interfaceLanguage)
            + (detail.isEmpty ? "" : "\n\n" + detail)
        return .init(body: displayed, original: request.text,
                     meta: [], source: title,
                     note: item.truncated ? L("apple.search.truncated") : nil,
                     actions: [Self.backAction(), openAction(item.id, shortcut: .commandO),
                               .init(kind: .copy(body), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc", shortcut: .commandC)])
    }

    private func subtitle(_ item: AppleProductivityItem, language: AppLanguage) -> String {
        var parts = [item.container]
        if kind == .notes {
            if item.locked { parts.append(L("apple.search.lockedLabel")) }
            if let modified = item.modified { parts.append(format(modified, language: language)) }
        } else {
            let overdue = item.due.map { item.allDay == true
                ? Calendar.current.startOfDay(for: $0) < Calendar.current.startOfDay(for: now()) : $0 < now() } == true
            parts.append(L(item.completed ? "apple.search.completed" : overdue
                ? "apple.search.overdue" : "apple.search.pending"))
            if let due = item.due { parts.append(L("apple.search.due", format(due, language: language, allDay: item.allDay == true))) }
            if let alarm = item.alarm { parts.append(L("apple.search.alarm", format(alarm, language: language))) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func format(_ date: Date, language: AppLanguage, allDay: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .short; formatter.timeStyle = allDay ? .none : .short
        return formatter.string(from: date)
    }

    private func openAction(_ id: String, shortcut: AskPluginAction.Shortcut) -> AskPluginAction {
        .init(kind: .rerun([Self.readOption: "", Self.openOption: id]), title: L("apple.search.openOriginal"),
              symbol: "arrow.up.forward.app", shortcut: shortcut)
    }

    private var settingsAction: AskPluginAction {
        .init(kind: .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_"
            + (kind == .reminders ? "Reminders" : "Automation"))!),
              title: L(kind == .reminders ? "apple.search.reminderPermissions" : "apple.permissions"),
              symbol: "lock.shield", shortcut: .commandO)
    }
}
