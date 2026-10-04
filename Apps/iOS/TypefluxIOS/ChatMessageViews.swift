import SwiftUI
import TypefluxChat
import UIKit

/// The owner supplies scrolling and composer placement so horizontal Markdown
/// tables and code blocks never create a second vertical transcript scroll view.
struct ChatTranscriptView: View {
    let conversation: ChatConversation
    var quote: (String) -> Void

    var body: some View {
        ForEach(ChatTranscript.items(conversation)) { item in
            switch item {
            case let .message(message): ChatMessageView(message: message, quote: quote)
            case let .activity(activity): ChatActivityView(activity: activity)
            }
        }
        if let run = conversation.run {
            VStack(alignment: .leading, spacing: 12) {
                if run.isActive {
                    Label(NSLocalizedString(run.requiresDesktop ? "Waiting for the originating device" :
                              "Typeflux is thinking…", comment: "Live response status"),
                    systemImage: run.requiresDesktop ? "desktopcomputer" : "sparkles")
                        .font(.subheadline).foregroundStyle(ChatTheme.textSecondary)
                        .accessibilityIdentifier("chat.run.status")
                }
                if let reasoning = run.reasoning, !reasoning.isEmpty,
                   run.isActive || ChatTranscript.preview(conversation) != nil {
                    ChatReasoningView(text: reasoning, milliseconds: run.reasoningMilliseconds,
                                      active: run.isActive && run.preview?.isEmpty != false)
                }
                if let preview = ChatTranscript.preview(conversation) {
                    ChatMarkdownView(text: preview).accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.run.preview")
                }
                if let error = run.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("chat.run.error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChatMessageView: View {
    let message: ChatMessage
    let quote: (String) -> Void
    @State private var copied = false

    var body: some View {
        Group {
            if message.role == "user" {
                userMessage
            } else if message.role == "tool" {
                orphanedToolResult
            } else {
                assistantMessage
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.message." + message.id)
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 36)
            VStack(alignment: .trailing, spacing: 8) {
                attachedImage
                if !message.text.isEmpty {
                    Text(message.text).font(.body).lineSpacing(3).textSelection(.enabled)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(ChatTheme.accent.opacity(0.18), in: bubble)
                        .overlay(bubble.strokeBorder(ChatTheme.accent.opacity(0.42), lineWidth: 0.5))
                }
            }
        }
    }

    private var bubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6,
                               topTrailingRadius: 20, style: .continuous)
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ChatReasoningView(text: reasoning, milliseconds: message.reasoningMilliseconds, active: false)
            }
            attachedImage
            if !message.text.isEmpty {
                ChatMarkdownView(text: message.text)
            }
            if message.isError == true {
                Label(
                    NSLocalizedString("Response interrupted", comment: "Incomplete answer"),
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption).foregroundStyle(ChatTheme.textSecondary)
            }
            if !message.text.isEmpty {
                HStack(spacing: 2) {
                    Button {
                        UIPasteboard.general.string = message.text; copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(NSLocalizedString(
                        copied ? "Copied" : "Copy response",
                        comment: "Message action"
                    ))
                    .accessibilityIdentifier("chat.copy." + message.id)
                    Button { quote(message.text) } label: {
                        Image(systemName: "text.quote").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(NSLocalizedString("Quote response", comment: "Message action"))
                    .accessibilityIdentifier("chat.quote." + message.id)
                }
                .font(.system(size: 14)).foregroundStyle(ChatTheme.textTertiary).buttonStyle(.plain)
                .padding(.leading, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: message.text) { _, _ in copied = false }
    }

    @ViewBuilder private var attachedImage: some View {
        if let image = message.image, let uiImage = ImageAttachment.decode(image) {
            Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(NSLocalizedString("Attached photo", comment: "Message image"))
        }
    }

    private var orphanedToolResult: some View {
        DisclosureGroup(NSLocalizedString(
            message.isError == true ? "Tool failed" : "View tool output",
            comment: "Tool output"
        )) {
            Text(message.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            attachedImage
        }
        .font(.subheadline).tint(ChatTheme.textSecondary)
    }
}

struct ChatReasoningView: View {
    let text: String
    let milliseconds: Int?
    let active: Bool
    @State private var expanded = false

    private var label: String {
        if active {
            return NSLocalizedString("Thinking…", comment: "Active reasoning")
        }
        if let milliseconds, milliseconds > 0 {
            return String(format: NSLocalizedString("Thought for %d seconds", comment: "Completed reasoning duration"),
                          max(1, milliseconds / 1000))
        }
        return NSLocalizedString("Thought process", comment: "Completed reasoning without duration")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(label)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.subheadline).foregroundStyle(ChatTheme.textSecondary)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(NSLocalizedString(expanded ? "Expanded" : "Collapsed", comment: "Disclosure state"))
            if expanded {
                ChatMarkdownView(text: text).foregroundStyle(ChatTheme.textSecondary).padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(ChatTheme.border).frame(width: 2) }
            }
        }
        .onChange(of: active) { _, value in
            if !value {
                expanded = false
            }
        }
    }
}

private struct ChatActivityView: View {
    let activity: ChatTranscript.Activity
    @State private var userExpanded: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expanded: Bool {
        userExpanded ?? activity.status.isExpandedByDefault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lead = activity.messages.first, let reasoning = lead.reasoning, !reasoning.isEmpty {
                ChatReasoningView(text: reasoning, milliseconds: lead.reasoningMilliseconds, active: false)
            }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { userExpanded = !expanded }
                } label: {
                    HStack(spacing: 10) {
                        ChatActivityStatusIcon(status: activity.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Agent activity", comment: "Activity group title"))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(String(
                                format: NSLocalizedString("%d steps · %@", comment: "Activity count and status"),
                                activity.steps.count,
                                activity.status.label
                            ))
                            .font(.caption).foregroundStyle(ChatTheme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(ChatTheme.textSecondary)
                    }
                    .padding(14).frame(minHeight: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.activity." + activity.id)
                .accessibilityValue(NSLocalizedString(expanded ? "Expanded" : "Collapsed", comment: "Disclosure state"))
                if expanded {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(activity.messages) { message in
                            if message.id != activity.messages.first?.id, let reasoning = message.reasoning,
                               !reasoning.isEmpty {
                                ChatReasoningView(
                                    text: reasoning,
                                    milliseconds: message.reasoningMilliseconds,
                                    active: false
                                )
                            }
                            if !message.text.isEmpty {
                                Text(message.text).font(.subheadline).foregroundStyle(ChatTheme.textSecondary)
                                    .textSelection(.enabled)
                            }
                            ForEach(activity.steps.filter { step in
                                (message.toolCalls ?? []).contains { $0.id == step.id }
                            }) { step in
                                ChatToolStepView(step: step)
                            }
                        }
                        ForEach(activity.steps.filter { step in
                            !activity.messages.contains { ($0.toolCalls ?? []).contains { $0.id == step.id } }
                        }) { step in ChatToolStepView(step: step) }
                    }.padding(14)
                }
            }
            .background(ChatTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                ChatTheme.border,
                lineWidth: 0.5
            ))
        }
        .onChange(of: activity.status) { old, new in
            if old.isExpandedByDefault, !new.isExpandedByDefault {
                userExpanded = nil
            }
        }
    }
}

private struct ChatToolStepView: View {
    let step: ChatTranscript.Step
    @State private var expanded = false
    @State private var showResult = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ChatToolPresentation.symbol(step.call))
                        .font(.system(size: 12)).foregroundStyle(ChatTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(ChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ChatToolPresentation.title(step.call)).font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let detail = ChatToolPresentation.detail(step.call) {
                            Text(detail).font(.caption).foregroundStyle(ChatTheme.textSecondary).lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(step.status.label).font(.caption)
                            .foregroundStyle(step.status == .failed ? .red : ChatTheme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(ChatTheme.textSecondary)
                }
                .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chat.tool." + step.id)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.call.function.name).font(.caption.monospaced()).foregroundStyle(ChatTheme.textSecondary)
                    if step.result != nil {
                        Picker(NSLocalizedString("Tool details", comment: "Tool detail pane"), selection: $showResult) {
                            Text(NSLocalizedString("Arguments", comment: "Tool detail pane")).tag(false)
                            Text(NSLocalizedString("Result", comment: "Tool detail pane")).tag(true)
                        }.pickerStyle(.segmented)
                    }
                    Text(showResult && step.result != nil ? step.result?.text ?? "" : step.call.function.arguments)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showResult, let image = step.result?.image, let uiImage = ImageAttachment.decode(image) {
                        Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 260)
                            .accessibilityLabel(NSLocalizedString("Tool result image", comment: "Tool image"))
                    }
                }
                .padding(12).background(ChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct ChatActivityStatusIcon: View {
    let status: ChatTranscript.Status

    var body: some View {
        Group {
            switch status {
            case .running: ProgressView().controlSize(.small)
            case .waiting: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .stopped: Image(systemName: "pause.circle.fill").foregroundStyle(ChatTheme.textSecondary)
            }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
