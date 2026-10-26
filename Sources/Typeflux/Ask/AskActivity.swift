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
    /// Entry file names of stored artifacts, by artifact id, from the steps that kept them.
    var storedArtifactNames: [String: String] = [:]
    var generatedImages: [AskGeneratedImage] = []
    var sources: [URL] = []

    var isEmpty: Bool { artifacts.isEmpty && storedArtifacts.isEmpty && generatedImages.isEmpty && sources.isEmpty }
}

/// Consecutive assistant steps that called tools, shown as one collapsible block.
struct AskActivityGroup: Equatable {
    /// The first step's message id, so scroll anchors keep pointing at a real message.
    var id: String
    var messages: [AskMessage]

    var messageIds: [String] { messages.map(\.id) }
    var calls: [AskToolCall] { messages.flatMap { $0.toolCalls ?? [] } }
    /// Calls shown as steps; plan updates are shown as the checklist instead.
    var steps: [AskToolCall] { calls.filter { !["update_plan", AskInternalRecovery.toolName].contains($0.function.name) } }
}

struct AskTranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case message(AskMessage)
        case activity(AskActivityGroup)
        case outcome(AskTaskOutcome)
    }

    var kind: Kind
    var isProgress = false
    /// Outputs belong to a stable task outcome, never to a transient assistant message.
    var outputs = AskRunOutputs()

    var id: String {
        switch kind {
        case let .message(message): isProgress ? message.id + "/progress" : message.id
        case let .activity(group): group.id
        case let .outcome(outcome): outcome.id
        }
    }
}

enum AskActivity {
    enum Category: String, CaseIterable {
        case search, web, files, code, computer, other

        static func of(_ name: String) -> Category {
            switch name {
            case "web_search", "research": .search
            case "web_fetch", "browser", AskEmbeddedBrowserTool.name: .web
            case "files", "project_files", "artifact": .files
            case "run_code", "run_command", "command_job": .code
            case "computer": .computer
            default: .other
            }
        }

        var title: String { L("ask.activity.kind." + rawValue) }
    }

    /// Splits a transcript (tool results excluded) into messages and activity blocks.
    /// `results` are the conversation's tool messages, used to collect outputs.
    static func items(_ messages: [AskMessage], results: [AskMessage],
                      fileChanges: [String: [AskWorkspaceFileChange]] = [:],
                      cache: AskActivityOutputCache? = nil) -> [AskTranscriptItem] {
        let index = resultIndex(results)
        var items: [AskTranscriptItem] = []
        var pending: [AskMessage] = []
        var taskMessages: [AskMessage] = []
        var taskID = messages.first.map { $0.runId ?? $0.id } ?? "empty"
        func flushSteps() {
            guard let first = pending.first else { return }
            items.append(.init(kind: .activity(.init(id: first.id, messages: pending))))
            pending = []
        }
        func flushOutcome() {
            let group = AskActivityGroup(id: taskID, messages: taskMessages)
            let outputs = cache?.outputs(group, results: index) ?? self.outputs(group, resultIndex: index)
            let changes = taskMessages.flatMap { fileChanges[$0.id] ?? [] }
            if !outputs.isEmpty || !changes.isEmpty {
                items.append(.init(kind: .outcome(.init(id: "outcome-" + taskID,
                                                       messageIDs: group.messageIds,
                                                       runIDs: Array(Set(taskMessages.compactMap(\.runId))).sorted(),
                                                       changes: AskConversationModel.merged([], changes))), outputs: outputs))
            }
            taskMessages = []
        }
        for message in messages {
            if message.role == "user", message.steered != true {
                flushSteps()
                flushOutcome()
                taskID = message.id
            }
            let isStep = message.role == "assistant" && !(message.toolCalls ?? []).isEmpty
            if isStep {
                var activity = message
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    flushSteps()
                    var note = message
                    note.toolCalls = nil
                    note.reasoning = nil
                    note.reasoningMilliseconds = nil
                    items.append(.init(kind: .message(note), isProgress: true))
                    activity.text = ""
                }
                pending.append(activity)
            } else {
                flushSteps()
                items.append(.init(kind: .message(message)))
            }
            if message.role == "assistant" { taskMessages.append(message) }
        }
        flushSteps()
        flushOutcome()
        cache?.retain(messages: messages)
        return items
    }

    static func resultIndex(_ results: [AskMessage]) -> [String: AskMessage] {
        Dictionary(results.compactMap { result in result.toolCallId.map { ($0, result) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Images produced by tools (screen and page captures are context, not results)
    /// and the pages read with web_fetch, in order and without duplicates.
    static func outputs(_ group: AskActivityGroup, results: [AskMessage]) -> AskRunOutputs {
        outputs(group, resultIndex: resultIndex(results))
    }

    static func outputs(_ group: AskActivityGroup, resultIndex: [String: AskMessage]) -> AskRunOutputs {
        var value = AskRunOutputs()
        for call in group.calls {
            let name = call.function.name
            if name == "web_fetch", let result = resultIndex[call.id], result.isError != true,
               let raw = (try? AskLocalTools.jsonArguments(call.function.arguments))?["url"] as? String,
               let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               !value.sources.contains(url) {
                value.sources.append(url)
            }
            if let result = resultIndex[call.id] {
                if ["image_generate", "image_edit"].contains(name), result.isError != true,
                   let image = result.generatedImage, image.safeURL != nil,
                   !value.generatedImages.contains(where: { $0.assetId == image.assetId }) {
                    value.generatedImages.append(image)
                }
                var refs = result.harness?.version == 1
                    ? (result.harness?.outcome?.artifacts ?? []) + (result.harness?.artifacts ?? []) : []
                if let receipt = try? JSONDecoder().decode(
                    AskArtifactReceipt.self, from: Data(result.resultText.utf8)
                ) {
                    refs.append(receipt.artifact)
                }
                if let receipt = AskGeneratedImageReceipt.parse(result.resultText) {
                    refs += receipt.generatedImages
                }
                let entry = name == "artifact"
                    ? ((try? AskLocalTools.jsonArguments(call.function.arguments))?["entry"] as? String)
                        .map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
                    : nil
                for ref in refs where !value.storedArtifacts.contains(where: { $0.id == ref.id }) {
                    value.storedArtifacts.append(ref)
                    if let entry { value.storedArtifactNames[ref.id] = entry }
                }
            }
            guard !["computer", "browser", AskEmbeddedBrowserTool.name].contains(name),
                  let result = resultIndex[call.id],
                  result.isError != true || result.harness?.outcome != nil else { continue }
            for (index, image) in result.retainedResultImages.enumerated() {
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
        for call in calls where !["update_plan", AskInternalRecovery.toolName].contains(call.function.name) {
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

    /// `paused` is a block whose run stopped for a recovery decision: it neither
    /// spins nor reads as finished.
    enum Status: Equatable { case running, attention, paused, failed, done }

    /// `live` marks the latest block of a run that is still working, even between steps;
    /// `halted` marks the latest block of a run that waits for the user to decide.
    static func status(_ group: AskActivityGroup, results: [AskMessage], streamingId: String?,
                       approvalToolId: String?, live: Bool = false, halted: Bool = false) -> Status {
        let resultsByID = resultIndex(results)
        if let approvalToolId, group.calls.contains(where: { $0.id == approvalToolId }) { return .attention }
        if halted { return .paused }
        if live { return .running }
        if let streamingId, group.messageIds.contains(streamingId) { return .running }
        if group.calls.contains(where: { call in resultsByID[call.id] == nil }) { return .running }
        if group.steps.contains(where: { call in
            let result = resultsByID[call.id]
            return result?.isRecoverableToolRefusal != true && AskPresentation.toolState(result: result) == .failed
        }) { return .failed }
        return .done
    }

    /// What the block did, in one line: the step itself when there is one,
    /// otherwise the kinds of steps it took; while working, the step under way.
    static func title(_ group: AskActivityGroup, status: Status, plan: [AskPlanItem]?, results: [AskMessage]) -> String {
        let steps = group.steps
        switch status {
        case .running, .paused:
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

    /// A waiting card's title: how far the plan has got, since the plan itself is
    /// listed under the title; without a plan, that something waits.
    static func attentionTitle(plan: [AskPlanItem]?) -> String {
        guard let plan, !plan.isEmpty else { return L("ask.activity.attention") }
        return L("ask.activity.plan", plan.filter { $0.status == "completed" }.count, plan.count)
    }

    /// The quieter tail of the line: "Step 3" while working, "3 steps" once
    /// there was more than one, nothing for a single step. `runStep` is the run's
    /// own count, shared with the header, for the block that carries the run.
    static func stepNote(_ group: AskActivityGroup, status: Status, runStep: Int? = nil) -> String? {
        let count = group.steps.count
        switch status {
        case .running:
            let step = runStep ?? count
            return step > 0 ? L("ask.activity.step", step) : nil
        case .paused: return L("ask.activity.pausedAt", max(runStep ?? count, 1))
        case .attention: return nil
        case .failed, .done: return count > 1 ? L("ask.activity.steps", count) : nil
        }
    }

    /// Steps whose result failed; only these are colored on the line.
    static func failures(_ group: AskActivityGroup, results: [AskMessage]) -> Int {
        group.steps.filter { call in
            let result = results.first { $0.toolCallId == call.id }
            return result?.isRecoverableToolRefusal != true && AskPresentation.toolState(result: result) == .failed
        }.count
    }

    /// The line's glyph: the first step's tool.
    static func symbol(_ group: AskActivityGroup) -> String {
        group.steps.first.map(AskPresentation.toolSymbol) ?? "list.bullet.clipboard"
    }
}
