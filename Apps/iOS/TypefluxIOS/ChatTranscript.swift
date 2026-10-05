import Foundation
import TypefluxChat

/// Presentation-only projection. Tool results stay attached to the calls that
/// produced them; a user turn always starts a new activity group.
enum ChatTranscript {
    enum Status: Equatable {
        case running, waiting, done, failed, stopped

        var label: String {
            let key = switch self {
            case .running: "Running"
            case .waiting: "Waiting for Mac"
            case .done: "Completed"
            case .failed: "Failed"
            case .stopped: "Interrupted"
            }
            return NSLocalizedString(key, comment: "Activity status")
        }
    }

    struct Step: Equatable, Identifiable {
        let call: ChatToolCall
        let result: ChatMessage?
        let status: Status
        var id: String {
            call.id
        }
    }

    struct Activity: Equatable, Identifiable {
        let id: String
        var messages: [ChatMessage]
        var steps: [Step]
        var status: Status
    }

    enum Item: Equatable, Identifiable {
        case message(ChatMessage)
        case activity(Activity)

        var id: String {
            switch self {
            case let .message(message): "message/" + message.id
            case let .activity(activity): "activity/" + activity.id
            }
        }
    }

    static func items(_ conversation: ChatConversation) -> [Item] {
        let messages = conversation.messages
        let allCallIDs = Set(messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
        let results = Dictionary(messages.filter { $0.role == "tool" && $0.toolCallId != nil }
            .map { ($0.toolCallId ?? "", $0) }, uniquingKeysWith: { _, newest in newest })
        var items: [Item] = []
        for message in messages {
            if message.role == "tool", let id = message.toolCallId, allCallIDs.contains(id) {
                continue
            }
            if message.role == "assistant", let calls = message.toolCalls, !calls.isEmpty {
                let steps = calls.map { step($0, result: results[$0.id], live: false, waiting: false) }
                if let last = items.last, case var .activity(activity) = last {
                    activity.messages.append(message)
                    activity.steps.append(contentsOf: steps)
                    items[items.count - 1] = .activity(activity)
                } else {
                    items.append(.activity(.init(id: message.id, messages: [message], steps: steps, status: .done)))
                }
            } else {
                items.append(.message(message))
            }
        }

        // Pending calls can arrive before their assistant message in a snapshot.
        // Include them once, without creating a second card when that message arrives.
        if let run = conversation.run, run.isActive {
            let pending = run.pending.filter { !allCallIDs.contains($0.id) }
                .map { step($0, result: results[$0.id], live: true, waiting: run.requiresDesktop) }
            if !pending.isEmpty {
                if let last = items.last, case var .activity(activity) = last {
                    activity.steps.append(contentsOf: pending)
                    items[items.count - 1] = .activity(activity)
                } else {
                    items.append(.activity(.init(
                        id: "pending/" + run.id,
                        messages: [],
                        steps: pending,
                        status: .running
                    )))
                }
            }
        }

        for index in items.indices {
            guard case var .activity(activity) = items[index] else { continue }
            let live = index == items.count - 1 && conversation.run?.isActive == true
            let waiting = live && conversation.run?.requiresDesktop == true
            activity.steps = activity.steps.map { step($0.call, result: $0.result, live: live, waiting: waiting) }
            activity.status = status(activity.steps, live: live, waiting: waiting)
            items[index] = .activity(activity)
        }
        return items
    }

    /// Tool steps in the latest turn: what the header's "N steps" counts.
    static func stepCount(_ conversation: ChatConversation) -> Int {
        let messages = conversation.messages
        let start = (messages.lastIndex(where: { $0.role == "user" }) ?? -1) + 1
        var ids = Set(messages[start...].flatMap { $0.toolCalls ?? [] }.map(\.id))
        if conversation.run?.isActive == true {
            ids.formUnion(conversation.run?.pending.map(\.id) ?? [])
        }
        return ids.count
    }

    /// What the turn's tools did, in one quiet line: the step itself when there
    /// is one, otherwise each distinct tool with its count; while working, the
    /// step under way.
    static func activityTitle(_ activity: Activity) -> String {
        switch activity.status {
        case .waiting: return NSLocalizedString("Waiting for Mac", comment: "Activity line title")
        case .running:
            return activity.steps.last.map(stepTitle)
                ?? NSLocalizedString("Using tools", comment: "Activity line title")
        case .done, .failed, .stopped:
            guard activity.steps.count != 1 else { return stepTitle(activity.steps[0]) }
            var counts: [(name: String, count: Int)] = []
            for step in activity.steps {
                let name = ChatToolPresentation.title(step.call)
                if let index = counts.firstIndex(where: { $0.name == name }) {
                    counts[index].count += 1
                } else {
                    counts.append((name, 1))
                }
            }
            return counts.map { $0.count > 1 ? $0.name + " " + String($0.count) : $0.name }
                .joined(separator: " · ")
        }
    }

    /// The quieter tail of the line: "Step 3" while working, "3 steps" once
    /// there was more than one, "Interrupted" when the run ended mid-step.
    static func activityNote(_ activity: Activity) -> String? {
        let count = activity.steps.count
        switch activity.status {
        case .running, .waiting:
            return String(format: NSLocalizedString("Step %d", comment: "Activity step"), max(1, count))
        case .stopped: return Status.stopped.label
        case .done, .failed:
            return count > 1 ? String(format: NSLocalizedString("%d steps", comment: "Activity step count"), count) : nil
        }
    }

    /// Steps whose result failed; only these are colored on the line.
    static func failures(_ activity: Activity) -> Int {
        activity.steps.filter { $0.status == .failed }.count
    }

    /// The line's glyph: the first step's tool.
    static func activitySymbol(_ activity: Activity) -> String {
        activity.steps.first.map { ChatToolPresentation.symbol($0.call) } ?? "list.bullet.clipboard"
    }

    /// A step's readable name with its target: "Search the web · WWDC dates".
    static func stepTitle(_ step: Step) -> String {
        let title = ChatToolPresentation.title(step.call)
        return ChatToolPresentation.detail(step.call).map { title + " · " + $0 } ?? title
    }

    static func preview(_ conversation: ChatConversation) -> String? {
        guard let text = conversation.run?.preview, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              conversation.messages.last(where: { $0.role == "assistant" })?.text != text else { return nil }
        return text
    }

    private static func step(_ call: ChatToolCall, result: ChatMessage?, live: Bool, waiting: Bool) -> Step {
        let status: Status = if let result {
            result.isError == true ? .failed : .done
        } else if live {
            waiting ? .waiting : .running
        } else {
            .stopped
        }
        return Step(call: call, result: result, status: status)
    }

    private static func status(_ steps: [Step], live: Bool, waiting: Bool) -> Status {
        if live {
            return waiting ? .waiting : .running
        }
        if steps.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if steps.contains(where: { $0.status == .stopped }) {
            return .stopped
        }
        return .done
    }
}

enum ChatToolPresentation {
    private static let titles = [
        "web_search": "Search the web", "web_fetch": "Read webpage", "research": "Research",
        "files": "Work with files", "project_files": "Work with files",
        "run_code": "Run code", "project_terminal": "Run code", "browser": "Browse the web",
        "computer": "Use computer", "memory": "Memory", "skill": "Use skill",
        "update_plan": "Update plan", "artifact": "Create artifact"
    ]

    static func title(_ call: ChatToolCall) -> String {
        let key = titles[call.function.name] ?? "Use tool"
        return NSLocalizedString(key, comment: "Readable tool title")
    }

    static func symbol(_ call: ChatToolCall) -> String {
        switch call.function.name {
        case "web_search", "research": "magnifyingglass"
        case "web_fetch", "browser": "globe"
        case "files", "project_files": "folder"
        case "run_code", "project_terminal": "terminal"
        case "computer": "desktopcomputer"
        case "memory": "brain"
        case "skill": "book"
        case "update_plan": "list.bullet.clipboard"
        case "artifact": "doc.richtext"
        default: "wrench.and.screwdriver"
        }
    }

    static func detail(_ call: ChatToolCall) -> String? {
        guard let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)))
            as? [String: Any] else { return nil }
        for key in ["query", "question", "url", "path", "name", "language"] {
            if let text = args[key] as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
