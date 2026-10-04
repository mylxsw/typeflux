import SwiftUI

/// Follow-ups waiting for the running conversation, on top of the composer. One
/// line by default: the count, the next message and its actions; expanding lists the rest.
struct AskQueueBar: View {
    @ObservedObject var model: AskConversationModel
    @Binding var expanded: Bool

    private var items: [AskQueuedMessage] { model.queuedMessages }

    var body: some View {
        if let first = items.first {
            VStack(alignment: .leading, spacing: 0) {
                row(first, index: 1, header: true)
                if expanded {
                    ForEach(Array(items.dropFirst().enumerated()), id: \.element.id) { offset, item in
                        Rectangle().fill(AskTheme.separator).frame(height: 1)
                        row(item, index: offset + 2, header: false)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(AskTheme.hoverFill.opacity(0.6))
            .overlay(alignment: .bottom) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.countText(items.count, paused: model.isQueuePaused))
        }
    }

    static func countText(_ count: Int, paused: Bool) -> String {
        let text = L("ask.queue.count", count)
        return paused ? text + " · " + L("ask.queue.paused") : text
    }

    /// Several lines of a queued message read as one line here.
    static func preview(_ draft: AskDraft) -> String {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        if !text.isEmpty { return text }
        return draft.references?.first { !$0.question.isEmpty }?.question ?? ""
    }

    private func row(_ item: AskQueuedMessage, index: Int, header: Bool) -> some View {
        let editing = model.sendQueue.isEditing(model.selectedId ?? "", itemId: item.id)
        return HStack(spacing: 8) {
            if header {
                Text(Self.countText(items.count, paused: model.isQueuePaused))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(AskTheme.hoverFill, in: Capsule())
            } else {
                Text("\(index)").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).monospacedDigit()
                    .frame(minWidth: 20, alignment: .trailing)
            }
            if editing {
                Text(L("ask.queue.editing"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(AskTheme.accentText)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(AskTheme.accentSoft, in: Capsule())
            }
            Text(Self.preview(item.draft))
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .help(item.draft.text)
                .onTapGesture(count: 2) { model.editQueued(item.id) }
            if (item.draft.includeScreenshot && item.draft.screenshot != nil) || item.draft.sentSelection != nil {
                Image(systemName: "paperclip").font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            Spacer(minLength: 6)
            if header, model.isQueuePaused {
                AskQueueAction(title: L("ask.queue.resume"), prominent: true) { model.resumeQueue() }
                AskQueueAction(title: L("ask.queue.clear")) { model.clearQueue() }
            }
            if !editing {
                if model.canSteer {
                    AskQueueAction(title: "↑ " + L("ask.queue.jump"), prominent: true) { model.steerQueued(item.id) }
                        .help(L("ask.queue.jump.help"))
                        .disabled(model.steeringIds.contains(item.id))
                }
                AskQueueIcon(symbol: "pencil", label: L("ask.queue.edit")) { model.editQueued(item.id) }
                AskQueueIcon(symbol: "xmark", label: L("ask.queue.remove")) { model.removeQueued(item.id) }
            }
            if header, items.count > 1 {
                AskQueueIcon(symbol: expanded ? "chevron.up" : "chevron.down",
                             label: L(expanded ? "ask.queue.collapse" : "ask.queue.expand")) { expanded.toggle() }
            } else if items.count > 1 {
                Color.clear.frame(width: 20, height: 1)
            }
        }
        .frame(minHeight: 34)
    }
}

private struct AskQueueAction: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(prominent ? AskTheme.accentText : StudioTheme.textSecondary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 22)
                .background(prominent ? AskTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AskQueueIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Shown above the editor while a queued message is open in it.
struct AskQueueEditingHeader: View {
    let index: Int
    let keepsDraft: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.system(size: 10.5, weight: .semibold))
            Text(L("ask.queue.editingTitle", index)).lineLimit(1)
            Spacer(minLength: 8)
            if keepsDraft { Text(L("ask.queue.stashed")).lineLimit(1).truncationMode(.head) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textSecondary)
    }
}

/// Replaces the send button while a queued message is being edited.
struct AskQueueEditActions: View {
    var canSave: Bool
    var compact = false
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                if compact { Image(systemName: "xmark") } else { Text(L("ask.queue.cancel")) }
            }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                .accessibilityLabel(L("ask.queue.cancel"))
                .accessibilityIdentifier("ask.queue.cancel")
            Button(action: onSave) {
                if compact {
                    Image(systemName: "checkmark")
                } else {
                    Label(L("ask.queue.save"), systemImage: "checkmark")
                }
            }
                .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                .disabled(!canSave)
                .accessibilityLabel(L("ask.queue.save"))
                .accessibilityIdentifier("ask.queue.save")
        }
    }
}
