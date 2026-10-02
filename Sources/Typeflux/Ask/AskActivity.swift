import Foundation

/// What a run produced besides its text: images made by tools and the pages it read.
struct AskRunOutputs: Equatable {
    struct Artifact: Equatable, Identifiable {
        var id: String
        var image: String
        var toolName: String
    }

    var artifacts: [Artifact] = []
    var sources: [URL] = []

    var isEmpty: Bool { artifacts.isEmpty && sources.isEmpty }
}

/// Consecutive assistant steps that called tools, shown as one collapsible block.
struct AskActivityGroup: Equatable {
    /// The first step's message id, so scroll anchors keep pointing at a real message.
    var id: String
    var messages: [AskMessage]

    var messageIds: [String] { messages.map(\.id) }
    var calls: [AskToolCall] { messages.flatMap { $0.toolCalls ?? [] } }
    /// Calls shown as steps; plan updates are shown as the checklist instead.
    var steps: [AskToolCall] { calls.filter { $0.function.name != "update_plan" } }
}

struct AskTranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case message(AskMessage)
        case activity(AskActivityGroup)
    }

    var kind: Kind
    /// Outputs of the activity before an answer render under that answer; a block with
    /// no answer after it yet keeps its own.
    var outputs = AskRunOutputs()

    var id: String {
        switch kind {
        case let .message(message): message.id
        case let .activity(group): group.id
        }
    }
}

enum AskActivity {
    enum Category: String, CaseIterable {
        case search, web, files, code, computer, other

        static func of(_ name: String) -> Category {
            switch name {
            case "web_search", "research": .search
            case "web_fetch", "browser": .web
            case "files": .files
            case "run_code": .code
            case "computer": .computer
            default: .other
            }
        }

        var title: String { L("ask.activity.kind." + rawValue) }
    }

    /// Splits a transcript (tool results excluded) into messages and activity blocks.
    /// `results` are the conversation's tool messages, used to collect outputs.
    static func items(_ messages: [AskMessage], results: [AskMessage]) -> [AskTranscriptItem] {
        var items: [AskTranscriptItem] = []
        for message in messages {
            let isStep = message.role == "assistant" && !(message.toolCalls ?? []).isEmpty
            if isStep, let last = items.last, case var .activity(group) = last.kind {
                group.messages.append(message)
                items[items.count - 1].kind = .activity(group)
            } else if isStep {
                items.append(.init(kind: .activity(AskActivityGroup(id: message.id, messages: [message]))))
            } else {
                items.append(.init(kind: .message(message)))
            }
        }
        for index in items.indices {
            guard case let .activity(group) = items[index].kind else { continue }
            let outputs = self.outputs(group, results: results)
            if index + 1 < items.count, case let .message(next) = items[index + 1].kind, next.role == "assistant" {
                items[index + 1].outputs = outputs
            } else {
                items[index].outputs = outputs
            }
        }
        return items
    }

    /// Images produced by tools (screen and page captures are context, not results)
    /// and the pages read with web_fetch, in order and without duplicates.
    static func outputs(_ group: AskActivityGroup, results: [AskMessage]) -> AskRunOutputs {
        var value = AskRunOutputs()
        for call in group.calls {
            let name = call.function.name
            if name == "web_fetch",
               let raw = (try? AskLocalTools.jsonArguments(call.function.arguments))?["url"] as? String,
               let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               !value.sources.contains(url) {
                value.sources.append(url)
            }
            guard !["computer", "browser"].contains(name),
                  let result = results.first(where: { $0.toolCallId == call.id }),
                  result.isError != true, let image = result.image else { continue }
            value.artifacts.append(.init(id: call.id, image: image, toolName: name))
        }
        return value
    }

    /// The plan shown in a block: the run's live plan for the latest block of the
    /// current run, otherwise the last plan the block itself recorded.
    static func plan(for group: AskActivityGroup, run: AskRun?, isLatest: Bool) -> [AskPlanItem]? {
        if isLatest, let plan = run?.plan, !plan.isEmpty,
           group.messages.contains(where: { $0.runId == nil || $0.runId == run?.id }) {
            return plan
        }
        guard let call = group.calls.last(where: { $0.function.name == "update_plan" }) else { return nil }
        return try? AskLocalEngine.parsePlan(call.function.arguments)
    }

    /// "Search 1 · Files 2 · Other 1", in a fixed order.
    static func categorySummary(_ calls: [AskToolCall]) -> String {
        var counts: [Category: Int] = [:]
        for call in calls where call.function.name != "update_plan" { counts[Category.of(call.function.name), default: 0] += 1 }
        return Category.allCases.compactMap { category in
            counts[category].map { category.title + " " + String($0) }
        }.joined(separator: " · ")
    }

    enum Status: Equatable { case running, attention, failed, done }

    /// `live` marks the latest block of a run that is still working, even between steps.
    static func status(_ group: AskActivityGroup, results: [AskMessage], streamingId: String?,
                       approvalToolId: String?, live: Bool = false) -> Status {
        if let approvalToolId, group.calls.contains(where: { $0.id == approvalToolId }) { return .attention }
        if live { return .running }
        if let streamingId, group.messageIds.contains(streamingId) { return .running }
        if group.calls.contains(where: { call in !results.contains { $0.toolCallId == call.id } }) { return .running }
        if group.steps.contains(where: { call in results.first { $0.toolCallId == call.id }?.isError == true }) { return .failed }
        return .done
    }

    static func title(_ group: AskActivityGroup, status: Status, plan: [AskPlanItem]?, results: [AskMessage]) -> String {
        let count = group.steps.count
        switch status {
        case .running: return L("ask.activity.running", count)
        case .attention: return L("ask.activity.attention")
        case .failed, .done:
            var title = L("ask.activity.done", count)
            if let plan, !plan.isEmpty {
                title = L("ask.activity.plan", plan.filter { $0.status == "completed" }.count, plan.count) + " · " + title
            }
            let failures = group.steps.filter { call in results.first { $0.toolCallId == call.id }?.isError == true }.count
            if failures > 0 { title += " · " + L("ask.activity.failures", failures) }
            return title
        }
    }

    /// The header's run line: where Ask runs, then the run's state and step count.
    static func runSummary(_ run: AskRun?, pendingApproval: Bool) -> String? {
        guard let run else { return nil }
        if pendingApproval { return L("ask.run.attention") }
        switch run.status {
        case "running", "waiting_tool", "waiting_inference": return L("ask.run.running", max(run.steps, 1))
        case "completed": return L("ask.run.completed", run.steps)
        case "failed": return L("ask.run.failed")
        case "cancelled": return L("ask.run.cancelled")
        default: return nil
        }
    }
}
