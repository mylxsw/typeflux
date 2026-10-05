// swiftlint:disable file_length
import SwiftUI
import TypefluxChat
import UIKit

/// The owner supplies scrolling and composer placement so horizontal Markdown
/// tables and code blocks never create a second vertical transcript scroll view.
struct ChatTranscriptView: View {
    let conversation: ChatConversation
    var allowsQuote = true
    var regenerableMessageID: String?
    var quote: (String) -> Void
    var regenerate: (String) -> Void = { _ in }

    var body: some View {
        ForEach(ChatTranscript.items(conversation)) { item in
            switch item {
            case let .message(message):
                ChatMessageView(message: message, allowsQuote: allowsQuote,
                                canRegenerate: message.id == regenerableMessageID,
                                quote: quote, regenerate: regenerate)
            case let .activity(activity): ChatActivityView(activity: activity)
            }
        }
        if let run = conversation.run {
            VStack(alignment: .leading, spacing: 10) {
                let preview = ChatTranscript.preview(conversation)
                if run.isActive, run.requiresDesktop {
                    Label(NSLocalizedString("Waiting for the originating device", comment: "Live response status"),
                          systemImage: "desktopcomputer")
                        .font(.system(size: 13.5)).foregroundStyle(ChatTheme.secondary)
                        .accessibilityIdentifier("chat.run.status")
                } else if let reasoning = run.reasoning, !reasoning.isEmpty, run.isActive || preview != nil {
                    ChatReasoningView(text: reasoning, milliseconds: run.reasoningMilliseconds,
                                      active: run.isActive && run.preview?.isEmpty != false)
                } else if run.isActive, preview == nil {
                    ChatThinkingLabel().accessibilityIdentifier("chat.run.status")
                }
                if let preview {
                    ChatMarkdownView(text: preview).accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.run.preview")
                    if run.isActive {
                        ChatStreamingDot()
                    }
                }
                runNotice(run)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func runNotice(_ run: ChatRun) -> some View {
        switch ChatPresentation.runNotice(run) {
        case .stopped:
            Label("Response stopped", systemImage: "stop.circle")
                .font(.system(size: 13.5)).foregroundStyle(ChatTheme.secondary)
                .accessibilityIdentifier("chat.run.stopped")
        case let .failure(error):
            Label(NSLocalizedString(error, comment: "Run error"), systemImage: "exclamationmark.circle")
                .font(.system(size: 13.5)).foregroundStyle(.red)
                .accessibilityIdentifier("chat.run.error")
        case nil:
            EmptyView()
        }
    }
}

private struct ChatMessageView: View {
    let message: ChatMessage
    let allowsQuote: Bool
    let canRegenerate: Bool
    let quote: (String) -> Void
    let regenerate: (String) -> Void
    @State private var copied = false
    @State private var selectingText = false

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
        .sheet(isPresented: $selectingText) { ChatTextSelectionSheet(text: message.text) }
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ChatMessageImages(message: message, maxWidth: 220)
            if !message.text.isEmpty {
                ChatSelectableText(blocks: [], plainText: message.text, foreground: UIColor(ChatTheme.bubbleText))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(ChatTheme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .padding(.top, 4)
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ChatReasoningView(text: reasoning, milliseconds: message.reasoningMilliseconds, active: false)
            }
            ChatMessageImages(message: message, maxWidth: .infinity)
            if !message.text.isEmpty {
                // No context menu here: it would take over the long press that selects text.
                ChatMarkdownView(text: message.text)
            }
            if message.isError == true {
                Label(NSLocalizedString("Response interrupted", comment: "Incomplete answer"),
                      systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(ChatTheme.secondary)
            }
            if !message.text.isEmpty {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: message.text) { _, _ in copied = false }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                UIPasteboard.general.string = message.text
                copied = true
            } label: { actionIcon(copied ? "checkmark" : "doc.on.doc") }
                .accessibilityLabel(NSLocalizedString(copied ? "Copied" : "Copy response", comment: "Message action"))
                .accessibilityIdentifier("chat.copy." + message.id)
                .foregroundStyle(copied ? ChatTheme.accent : ChatTheme.tertiary)
            Button { selectingText = true } label: { actionIcon("text.cursor") }
                .accessibilityLabel(NSLocalizedString("Select text", comment: "Message action"))
                .accessibilityIdentifier("chat.select." + message.id)
            Button { quote(message.text) } label: { actionIcon("text.quote") }
                .accessibilityLabel(NSLocalizedString("Quote response", comment: "Message action"))
                .accessibilityIdentifier("chat.quote." + message.id)
                .disabled(!allowsQuote)
            if canRegenerate {
                Button { regenerate(message.id) } label: { actionIcon("arrow.clockwise") }
                    .accessibilityLabel(NSLocalizedString("Regenerate", comment: "Message action"))
                    .accessibilityIdentifier("chat.regenerate." + message.id)
            }
            ShareLink(item: message.text) { actionIcon("square.and.arrow.up") }
                .accessibilityLabel(NSLocalizedString("Share", comment: "Message action"))
                .accessibilityIdentifier("chat.share." + message.id)
        }
        .foregroundStyle(ChatTheme.tertiary).buttonStyle(.plain)
        .padding(.leading, -11).padding(.top, -6)
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14.5)).frame(width: 36, height: 36).contentShape(Rectangle())
    }

    private var orphanedToolResult: some View {
        DisclosureGroup(NSLocalizedString(message.isError == true ? "Tool failed" : "View tool output",
                                          comment: "Tool output")) {
            Text(message.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChatMessageImages(message: message, maxWidth: .infinity)
        }
        .font(.subheadline).tint(ChatTheme.textSecondary)
    }
}

private struct ChatMessageImages: View {
    let message: ChatMessage
    let maxWidth: CGFloat

    var body: some View {
        ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
            if let uiImage = ImageAttachment.decode(dataURL) {
                Image(uiImage: uiImage).resizable().scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(ChatTheme.border, lineWidth: 0.5))
                    .accessibilityLabel(NSLocalizedString("Attached photo", comment: "Message image"))
                    .accessibilityIdentifier("chat.photo.\(message.id).\(index)")
            }
        }
    }
}

/// "Thought for N seconds ›", expanding to the reasoning text, as on the Mac.
struct ChatReasoningView: View {
    let text: String
    let milliseconds: Int?
    let active: Bool
    @State private var expanded = false

    private var label: String {
        if let milliseconds, milliseconds > 0 {
            return String(format: NSLocalizedString("Thought for %d seconds", comment: "Completed reasoning duration"),
                          max(1, milliseconds / 1000))
        }
        return NSLocalizedString("Thought process", comment: "Completed reasoning without duration")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                if active {
                    ChatThinkingLabel()
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(ChatTheme.tertiary)
                        Text(label)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.system(size: 13.5)).foregroundStyle(ChatTheme.secondary)
                    .frame(minHeight: 30).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(NSLocalizedString(expanded ? "Expanded" : "Collapsed", comment: "Disclosure state"))
            if expanded {
                ChatMarkdownView(text: text).font(.system(size: 14)).foregroundStyle(ChatTheme.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(ChatTheme.border).frame(width: 1.5) }
            }
        }
        .onChange(of: active) { _, value in
            if !value {
                expanded = false
            }
        }
    }
}

/// "Thinking" in a soft moving highlight; Reduce Motion shows plain text.
struct ChatThinkingLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(ChatTheme.accent)
            if reduceMotion {
                Text("Thinking…").foregroundStyle(ChatTheme.secondary)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Text("Thinking…")
                        .foregroundStyle(LinearGradient(
                            stops: [.init(color: ChatTheme.secondary, location: phase - 0.3),
                                    .init(color: .primary, location: phase),
                                    .init(color: ChatTheme.secondary, location: phase + 0.3)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                }
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

/// The breathing dot at the end of a reply that is still being written.
struct ChatStreamingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle().fill(ChatTheme.accent).frame(width: 8, height: 8)
            .background(Circle().fill(ChatTheme.accent.opacity(0.18)).frame(width: 16, height: 16)
                .scaleEffect(pulse ? 1 : 0.6))
            .frame(width: 16, height: 16)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

/// One turn of tool use as a single quiet line above the answer, like the
/// reasoning row: what the tools did, unfolded on tap into their steps. Success
/// stays silent; only failures are colored.
private struct ChatActivityView: View {
    let activity: ChatTranscript.Activity
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lead = activity.messages.first, let reasoning = lead.reasoning, !reasoning.isEmpty {
                ChatReasoningView(text: reasoning, milliseconds: lead.reasoningMilliseconds, active: false)
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                ChatActivityLine(activity: activity, expanded: expanded)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.activity." + activity.id)
            .accessibilityValue(NSLocalizedString(expanded ? "Expanded" : "Collapsed", comment: "Disclosure state"))
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(activity.messages) { message in
                        if message.id != activity.messages.first?.id, let reasoning = message.reasoning,
                           !reasoning.isEmpty {
                            ChatReasoningView(text: reasoning, milliseconds: message.reasoningMilliseconds,
                                              active: false)
                        }
                        if !message.text.isEmpty {
                            Text(message.text).font(.system(size: 13.5)).foregroundStyle(ChatTheme.secondary)
                                .textSelection(.enabled).padding(.vertical, 2)
                        }
                        ForEach(activity.steps.filter { step in
                            (message.toolCalls ?? []).contains { $0.id == step.id }
                        }) { step in ChatToolStepView(step: step) }
                    }
                    ForEach(activity.steps.filter { step in
                        !activity.messages.contains { ($0.toolCalls ?? []).contains { $0.id == step.id } }
                    }) { step in ChatToolStepView(step: step) }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(ChatTheme.border).frame(width: 1.5) }
                .padding(.bottom, 4)
            }
        }
    }
}

/// The activity's folded line: tool glyph (or spinner), what was done, a quiet
/// step note, failures in red, and a chevron.
struct ChatActivityLine: View {
    let activity: ChatTranscript.Activity
    var expanded = false

    var body: some View {
        let failures = ChatTranscript.failures(activity)
        HStack(spacing: 6) {
            Group {
                switch activity.status {
                case .running: ChatSpinner(size: 14)
                case .waiting:
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                default: Image(systemName: ChatTranscript.activitySymbol(activity)).font(.system(size: 12))
                }
            }
            .frame(width: 16, height: 16)
            Text(ChatTranscript.activityTitle(activity))
                .foregroundStyle(activity.status == .waiting ? Color.orange : ChatTheme.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let note = ChatTranscript.activityNote(activity) {
                Text("· " + note).lineLimit(1).layoutPriority(1)
            }
            if failures > 0 {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(String(format: NSLocalizedString("%d failed", comment: "Failed tool steps"), failures))
                }
                .foregroundStyle(.red).lineLimit(1).layoutPriority(1)
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .font(.system(size: 13.5))
        .foregroundStyle(ChatTheme.tertiary)
        .frame(minHeight: 30).contentShape(Rectangle())
    }
}

private struct ChatToolStepView: View {
    let step: ChatTranscript.Step
    @State private var expanded = false
    @State private var showResult = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    if step.status == .done {
                        Image(systemName: ChatToolPresentation.symbol(step.call)).font(.system(size: 11))
                            .foregroundStyle(ChatTheme.tertiary).frame(width: 14, height: 14)
                    } else {
                        ChatActivityStatusIcon(status: step.status, size: 14)
                    }
                    (Text(ChatToolPresentation.title(step.call)).foregroundStyle(ChatTheme.secondary)
                        + Text(ChatToolPresentation.detail(step.call).map { " · " + $0 } ?? "")
                        .foregroundStyle(ChatTheme.tertiary))
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if step.status == .failed || step.status == .stopped {
                        Text(step.status.label).font(.system(size: 12))
                            .foregroundStyle(step.status == .failed ? Color.red : ChatTheme.tertiary)
                    }
                }
                .frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("chat.tool." + step.id)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.call.function.name).font(.caption.monospaced()).foregroundStyle(ChatTheme.secondary)
                    if step.result != nil {
                        Picker(NSLocalizedString("Tool details", comment: "Tool detail pane"), selection: $showResult) {
                            Text(NSLocalizedString("Arguments", comment: "Tool detail pane")).tag(false)
                            Text(NSLocalizedString("Result", comment: "Tool detail pane")).tag(true)
                        }.pickerStyle(.segmented)
                    }
                    Text(showResult && step.result != nil ? step.result?.text ?? "" : step.call.function.arguments)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showResult, let result = step.result {
                        ChatMessageImages(message: result, maxWidth: .infinity)
                    }
                }
                .padding(12).background(ChatTheme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 4)
            }
        }
    }
}

private struct ChatActivityStatusIcon: View {
    let status: ChatTranscript.Status
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch status {
            case .running: ChatSpinner(size: size)
            case .waiting: Image(systemName: "exclamationmark.circle.fill").resizable().foregroundStyle(.orange)
            case .done:
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(ChatTheme.success, in: Circle())
            case .failed: Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(.red)
            case .stopped: Image(systemName: "pause.circle.fill").resizable().foregroundStyle(ChatTheme.secondary)
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A thin accent ring; Reduce Motion keeps it still.
struct ChatSpinner: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(ChatTheme.accent.opacity(0.22), lineWidth: 2)
            Circle().trim(from: 0, to: 0.28).stroke(ChatTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size - 2, height: size - 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}
