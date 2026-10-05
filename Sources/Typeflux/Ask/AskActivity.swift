import Foundation

/// What a run produced besides its text: images made by tools and the pages it read.
struct AskRunOutputs: Equatable {
    struct Artifact: Equatable, Identifiable {
        var id: String
        var image: String
        var toolName: String
    }

    var artifacts: [Artifact] = []
    var storedArtifacts: [AskArtifactRef] = []
    var sources: [URL] = []

    var isEmpty: Bool { artifacts.isEmpty && storedArtifacts.isEmpty && sources.isEmpty }
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
            case "files", "project_files", "artifact": .files
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
            if let result = results.first(where: { $0.toolCallId == call.id }) {
                var refs = result.harness?.version == 1
                    ? (result.harness?.outcome?.artifacts ?? []) + (result.harness?.artifacts ?? []) : []
                if let receipt = try? JSONDecoder().decode(
                    AskArtifactReceipt.self, from: Data(result.resultText.utf8)
                ) {
                    refs.append(receipt.artifact)
                }
                for ref in refs where !value.storedArtifacts.contains(where: { $0.id == ref.id }) {
                    value.storedArtifacts.append(ref)
                }
            }
            guard !["computer", "browser"].contains(name),
                  let result = results.first(where: { $0.toolCallId == call.id }),
                  result.isError != true || result.harness?.outcome != nil else { continue }
            for (index, image) in result.resultImages.enumerated() {
                value.artifacts.append(.init(id: index == 0 ? call.id : call.id + "/" + String(index),
                                             image: image, toolName: name))
            }
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

    /// "Search 2 · Files 1 · Memory", in a fixed order. Calls that fit no category
    /// are named by their tool rather than lumped together as "Other".
    static func categorySummary(_ calls: [AskToolCall]) -> String {
        var counts: [Category: Int] = [:]
        var others: [(name: String, count: Int)] = []
        for call in calls where call.function.name != "update_plan" {
            let category = Category.of(call.function.name)
            guard category == .other else { counts[category, default: 0] += 1; continue }
            let name = toolName(call)
            if let index = others.firstIndex(where: { $0.name == name }) {
                others[index].count += 1
            } else {
                others.append((name, 1))
            }
        }
        let known = Category.allCases.compactMap { category in
            counts[category].map { category.title + " " + String($0) }
        }
        return (known + others.map { $0.count > 1 ? $0.name + " " + String($0.count) : $0.name })
            .joined(separator: " · ")
    }

    /// The tool part of a readable title: "Memory" for "Memory · List".
    static func toolName(_ call: AskToolCall) -> String {
        let title = AskTheme.toolTitle(call)
        return title.components(separatedBy: " · ").first ?? title
    }

    enum Status: Equatable { case running, attention, failed, done }

    /// `live` marks the latest block of a run that is still working, even between steps.
    static func status(_ group: AskActivityGroup, results: [AskMessage], streamingId: String?,
                       approvalToolId: String?, live: Bool = false) -> Status {
        if let approvalToolId, group.calls.contains(where: { $0.id == approvalToolId }) { return .attention }
        if live { return .running }
        if let streamingId, group.messageIds.contains(streamingId) { return .running }
        if group.calls.contains(where: { call in !results.contains { $0.toolCallId == call.id } }) { return .running }
        if group.steps.contains(where: { call in
            AskPresentation.toolState(result: results.first { $0.toolCallId == call.id }) == .failed
        }) { return .failed }
        return .done
    }

    /// What the block did, in one line: the step itself when there is one,
    /// otherwise the kinds of steps it took; while working, the step under way.
    static func title(_ group: AskActivityGroup, status: Status, plan: [AskPlanItem]?, results: [AskMessage]) -> String {
        let steps = group.steps
        switch status {
        case .running:
            return steps.last.map { AskTheme.toolTitle($0) } ?? L("ask.activity.working")
        case .attention: return L("ask.activity.attention")
        case .failed, .done:
            var parts: [String] = []
            if let plan, !plan.isEmpty {
                parts.append(L("ask.activity.plan", plan.filter { $0.status == "completed" }.count, plan.count))
            }
            if steps.count == 1, parts.isEmpty {
                parts.append(AskTheme.toolTitle(steps[0]))
            } else if !steps.isEmpty {
                parts.append(categorySummary(steps))
            }
            // A block that only updated its plan, with the plan itself gone.
            return parts.isEmpty ? L("ask.tool.update_plan") : parts.joined(separator: " · ")
        }
    }

    /// The quieter tail of the line: "Step 3" while working, "3 steps" once
    /// there was more than one, nothing for a single step.
    static func stepNote(_ group: AskActivityGroup, status: Status) -> String? {
        let count = group.steps.count
        switch status {
        case .running: return count > 0 ? L("ask.activity.step", count) : nil
        case .attention: return nil
        case .failed, .done: return count > 1 ? L("ask.activity.steps", count) : nil
        }
    }

    /// Steps whose result failed; only these are colored on the line.
    static func failures(_ group: AskActivityGroup, results: [AskMessage]) -> Int {
        group.steps.filter { call in
            AskPresentation.toolState(result: results.first { $0.toolCallId == call.id }) == .failed
        }.count
    }

    /// The line's glyph: the first step's tool.
    static func symbol(_ group: AskActivityGroup) -> String {
        group.steps.first.map(AskPresentation.toolSymbol) ?? "list.bullet.clipboard"
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
