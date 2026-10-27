import SwiftUI

/// Presentation-only grouping keeps persisted messages, receipt caches and output ownership intact.
struct AskTranscriptSection: Identifiable {
    let id: String
    var items: [AskTranscriptItem]
    var isProcess = false
    var hasConclusion = false

    var runIDs: Set<String> {
        Set(items.flatMap { item -> [String] in
            switch item.kind {
            case let .message(message): return [message.runId].compactMap(\.self)
            case let .activity(group): return group.messages.compactMap(\.runId)
            case .outcome: return []
            }
        })
    }

    var toolCount: Int {
        items.reduce(0) { count, item in
            if case let .activity(group) = item.kind { return count + group.steps.count }
            return count
        }
    }

    func contains(_ messageID: String?) -> Bool { index(of: messageID) != nil }

    func index(of messageID: String?) -> Int? {
        guard let messageID else { return nil }
        return items.firstIndex { item in
            switch item.kind {
            case let .message(message): message.id == messageID
            case let .activity(group): group.messageIds.contains(messageID)
            case .outcome: false
            }
        }
    }

    /// The last answer stays outside the process. Earlier narration and reasoning belong
    /// to the same disclosure as the tools. A new user turn always starts a new disclosure.
    static func make(_ items: [AskTranscriptItem], activeRunID: String? = nil,
                     activeMessageID: String? = nil) -> [Self] {
        var sections: [Self] = []
        var turn: [AskTranscriptItem] = []
        func flushTurn() {
            let isActive = turn.contains { item in
                switch item.kind {
                case let .message(message):
                    return message.role == "assistant" && ((activeRunID != nil && message.runId == activeRunID)
                        || (activeMessageID != nil && message.id == activeMessageID))
                case let .activity(group):
                    return group.messages.contains { message in
                        (activeRunID != nil && message.runId == activeRunID)
                            || (activeMessageID != nil && message.id == activeMessageID)
                    }
                case .outcome: return false
                }
            }
            let answerID = isActive ? nil : turn.last { item in
                if case let .message(message) = item.kind {
                    return message.role == "assistant" && !item.isProgress
                        && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }?.viewID
            var process: [AskTranscriptItem] = []
            func flushProcess() {
                guard let first = process.first else { return }
                sections.append(.init(id: "process/" + first.viewID, items: process,
                                      isProcess: true, hasConclusion: answerID != nil))
                process = []
            }
            for item in turn {
                switch item.kind {
                case let .message(message) where message.role == "assistant":
                    if item.viewID == answerID {
                        var answer = message
                        if let reasoning = message.reasoning, !reasoning.isEmpty {
                            var thought = message
                            thought.id += "/reasoning"
                            thought.text = ""
                            process.append(.init(kind: .message(thought), isProgress: true))
                            answer.reasoning = nil
                            answer.reasoningMilliseconds = nil
                        }
                        flushProcess()
                        sections.append(.init(id: item.viewID, items: [.init(kind: .message(answer))]))
                    } else { process.append(item) }
                case .activity:
                    process.append(item)
                default:
                    flushProcess()
                    sections.append(.init(id: item.viewID, items: [item]))
                }
            }
            flushProcess()
            turn = []
        }
        for item in items {
            if case let .message(message) = item.kind, message.role == "user", message.steered != true {
                flushTurn()
            }
            turn.append(item)
        }
        flushTurn()
        return sections
    }
}

/// A completed turn leaves one quiet disclosure immediately above its answer.
struct AskTurnProcessView<Content: View>: View {
    let section: AskTranscriptSection
    let active: Bool
    var locatedMessageID: String?
    var startsExpanded: Bool?
    @ViewBuilder var content: ([AskTranscriptItem]) -> Content
    @State private var detailPage: Int?
    @State private var userExpanded: Bool?
    @Environment(\.askInspectTranscript) private var inspectTranscript

    private var expanded: Bool {
        userExpanded ?? startsExpanded ?? (active || !section.hasConclusion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                inspectTranscript()
                userExpanded = !expanded
            } label: {
                HStack(spacing: 6) {
                    Text(L(active ? "ask.activity.working" : "ask.activity.process"))
                    if section.toolCount > 0 { Text("· " + L("ask.activity.steps", section.toolCount)) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.turn.process")
            .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
            if expanded {
                let page = detailPage ?? (active ? AskActivityPage.last(count: section.items.count) : 0)
                let range = AskActivityPage.range(count: section.items.count, page: page)
                if section.items.count > AskActivityPage.size {
                    HStack(spacing: 12) {
                        Button(L("ask.activity.previous")) { detailPage = max(0, page - 1) }
                            .disabled(range.lowerBound == 0)
                        Text(L("ask.activity.page", range.lowerBound + 1, range.upperBound, section.items.count))
                        Button(L("ask.activity.next")) { detailPage = page + 1 }
                            .disabled(range.upperBound == section.items.count)
                        Button(L("ask.activity.latest")) {
                            detailPage = active ? nil : AskActivityPage.last(count: section.items.count)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                }
                content(Array(section.items[range]))
            }
        }
        // Completion folds even a process the user inspected while it was running.
        .onChange(of: active) { _ in userExpanded = nil }
        .onChange(of: section.hasConclusion) { _ in userExpanded = nil }
        .onChange(of: locatedMessageID) { id in
            if let index = section.index(of: id) {
                detailPage = index / AskActivityPage.size
                userExpanded = true
            }
        }
    }
}
