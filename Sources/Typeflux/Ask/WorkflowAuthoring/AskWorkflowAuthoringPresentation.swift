import Foundation

/// The draft panel's completeness checklist: each problem is attached to the
/// item it concerns instead of being listed in red under the panel.
struct AskWorkflowChecklist: Equatable {
    enum Item: String, CaseIterable, Equatable {
        case details, script, keywords

        var titleKey: String { "ask.workflow.chat.check." + rawValue }
    }

    struct Row: Equatable {
        var item: Item
        var problems: [String]
        /// What is there when complete; the first problem otherwise.
        var detail: String

        var isComplete: Bool { problems.isEmpty }
    }

    var rows: [Row]

    init(manifest: AskWorkflowManifest?, problems: [AskWorkflowManifest.Problem]) {
        var grouped: [Item: [String]] = [:]
        for problem in problems {
            grouped[Self.item(for: problem.field), default: []].append(problem.message)
        }
        rows = Item.allCases.map { item in
            let messages = grouped[item] ?? []
            return Row(item: item, problems: messages,
                       detail: messages.first ?? Self.summary(of: item, manifest: manifest))
        }
    }

    var completed: Int { rows.filter(\.isComplete).count }
    var missing: Int { rows.count - completed }
    var isComplete: Bool { missing == 0 }

    /// The checklist item a manifest field belongs to. Identity fields and an
    /// unreadable manifest count as the name and description.
    static func item(for field: String) -> Item {
        switch AskWorkflowDraft.step(for: field) {
        case .keywords: .keywords
        case .script, .input, .output: .script
        case nil: .details
        }
    }

    static func summary(of item: Item, manifest: AskWorkflowManifest?) -> String {
        guard let manifest else { return "" }
        switch item {
        case .details:
            return [manifest.name, manifest.description].compactMap { value in
                value.flatMap { $0.isEmpty ? nil : $0 }
            }.joined(separator: " · ")
        case .script:
            return manifest.command.script ?? L("ask.workflow.chat.check.inlineScript")
        case .keywords:
            return manifest.keywords.map(\.keyword).joined(separator: L("ask.workflow.chat.check.separator"))
        }
    }

    /// What the AI is asked to finish, in the conversation that wrote the draft.
    var completionRequest: String {
        let missing = rows.filter { !$0.isComplete }
            .map { "- " + L($0.item.titleKey) + ": " + $0.problems.joined(separator: "; ") }
        return L("ask.workflow.chat.completePrompt") + "\n" + missing.joined(separator: "\n")
    }
}

/// The draft's state as the transcript card and the panel header show it.
enum AskWorkflowDraftStatus: Equatable {
    case incomplete(missing: Int)
    case draft
    case saved

    static func resolve(checklist: AskWorkflowChecklist, isDirty: Bool) -> AskWorkflowDraftStatus {
        if !checklist.isComplete { return .incomplete(missing: checklist.missing) }
        return isDirty ? .draft : .saved
    }

    /// The panel's short badge.
    var badge: String {
        switch self {
        case .incomplete: L("ask.workflow.chat.status.incomplete")
        case .draft: L("ask.workflow.chat.status.draft")
        case .saved: L("ask.workflow.chat.status.saved")
        }
    }

    /// The transcript card's longer label.
    var cardLabel: String {
        switch self {
        case let .incomplete(missing): L("ask.workflow.chat.status.missing", missing)
        case .draft: L("ask.workflow.chat.status.unsaved")
        case .saved: L("ask.workflow.chat.saved")
        }
    }
}

/// The line under the panel's Save button: why it cannot be pressed, or what to do next.
enum AskWorkflowSaveHint: Equatable {
    case completeFirst(missing: Int)
    case running
    case testFirst
    case tested
    case testFailed
    case saved(keyword: String?)

    static func resolve(status: AskWorkflowDraftStatus, isRunning: Bool,
                        lastResult: AskWorkflowTestResult?, keyword: String?) -> AskWorkflowSaveHint {
        switch status {
        case let .incomplete(missing): return .completeFirst(missing: missing)
        case .saved: return .saved(keyword: keyword.flatMap { $0.isEmpty ? nil : $0 })
        case .draft:
            if isRunning { return .running }
            guard let lastResult else { return .testFirst }
            return lastResult.succeeded ? .tested : .testFailed
        }
    }

    /// Save is possible: nothing is missing, nothing is running and there are changes.
    var allowsSave: Bool {
        switch self {
        case .testFirst, .tested, .testFailed: true
        case .completeFirst, .running, .saved: false
        }
    }

    /// Green for a passing test or a saved tool; the neutral caption otherwise.
    var isPositive: Bool {
        switch self {
        case .tested, .saved: true
        default: false
        }
    }

    var text: String {
        switch self {
        case let .completeFirst(missing): L("ask.workflow.chat.hint.complete", missing)
        case .running: L("ask.workflow.chat.hint.running")
        case .testFirst: L("ask.workflow.chat.hint.testFirst")
        case .tested: L("ask.workflow.chat.hint.tested")
        case .testFailed: L("ask.workflow.chat.hint.testFailed")
        case let .saved(keyword):
            keyword.map { L("ask.workflow.chat.hint.savedKeyword", $0) } ?? L("ask.workflow.chat.saved")
        }
    }
}
