import SwiftUI

/// Feedback from submission until the current assistant step starts writing.
enum AskResponseWaiting {
    static func isVisible(phase: AskRunPhase?, pendingSubmission: Bool, run: AskRun?,
                          messages: [AskMessage], progress: AskStreamProgress?, hasError: Bool) -> Bool {
        isVisible(phase: phase, pendingSubmission: pendingSubmission, run: run,
                  hasAnswerText: messages.last(where: { $0.id == run?.assistantId && $0.role == "assistant" })
                    .map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false,
                  progress: progress, hasError: hasError)
    }

    static func isVisible(phase: AskRunPhase?, pendingSubmission: Bool, run: AskRun?,
                          hasAnswerText: @autoclosure () -> Bool, progress: AskStreamProgress?, hasError: Bool) -> Bool {
        guard phase?.isWorking == true, !hasError else { return false }
        // A follow-up still carries the previous run while submission is in flight.
        if pendingSubmission { return true }
        guard let run, run.isActive else { return false }
        if let progress, !progress.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return !hasAnswerText()
    }

    static let period = 1.4
    static let stagger = 0.24

    /// A smooth pulse with a continuous slope, including at the loop boundary.
    static func opacity(dot: Int, elapsed: TimeInterval) -> Double {
        let phase = (elapsed - Double(dot) * stagger) / period * 2 * .pi
        let pulse = pow((cos(phase) + 1) / 2, 3)
        return 0.25 + 0.7 * pulse
    }
}

/// Only the dots redraw each frame; the transcript and its scroll anchors stay still.
struct AskResponseWaitingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        Group {
            if reduceMotion {
                bubble(elapsed: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    bubble(elapsed: context.date.timeIntervalSince(startedAt))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("ask.working"))
        .accessibilityIdentifier("ask.response.waiting")
        .allowsHitTesting(false)
    }

    func bubble(elapsed: TimeInterval?) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(StudioTheme.textSecondary)
                    .opacity(elapsed.map { AskResponseWaiting.opacity(dot: index, elapsed: $0) } ?? 0.65)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(AskTheme.hoverFill, in: Capsule())
    }
}

extension AskConversationModel {
    /// A durable message fact, invalidated with the selected snapshot, not each stream delta.
    var runHasResponseText: Bool {
        if let cachedRunHasResponseText { return cachedRunHasResponseText }
        let value = selected
        let answer = value?.messages.last(where: { $0.id == value?.run?.assistantId && $0.role == "assistant" })
        let result = answer.map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        cachedRunHasResponseText = result
        return result
    }

    var showsResponseWaiting: Bool {
        guard let value = selected else { return false }
        return AskResponseWaiting.isVisible(
            phase: runPhase, pendingSubmission: hasPendingSubmission, run: value.run,
            hasAnswerText: runHasResponseText, progress: liveProgress(value), hasError: error != nil)
    }
}
