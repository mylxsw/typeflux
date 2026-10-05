import SwiftUI

/// Leads the launcher's first row while recording, in place of the context
/// token: a microphone dot that swells with the voice, then a still waveform
/// while the words are recognised (the stop button shows the progress).
struct AskVoiceOrb: View {
    @ObservedObject var live: AskVoiceLive
    var listening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 30

    /// 0.9 at silence up to 1.15 at full level.
    static func scale(level: Float) -> CGFloat { 0.9 + 0.25 * CGFloat(min(1, max(0, level))) }

    var body: some View {
        ZStack {
            if listening {
                Circle().fill(AskTheme.accent.opacity(0.18))
                    .scaleEffect(reduceMotion ? 1 : Self.scale(level: live.levels.last ?? 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: live.levels.last)
                Circle().fill(AskTheme.accent).frame(width: 20, height: 20)
                Image(systemName: "mic.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            } else {
                Circle().fill(AskTheme.accent.opacity(0.14))
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AskTheme.accent)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(listening ? "ask.voice.listening" : "ask.voice.transcribing"))
    }
}

/// The words recognised so far, shown in the editor's place while recording:
/// what the recogniser has committed in the primary colour, the guess after it
/// dimmed. Before any words it shows the draft, or says that it is listening.
struct AskVoiceLiveText: View {
    @ObservedObject var live: AskVoiceLive
    var listening: Bool
    /// The draft's text; the recognised words follow it.
    var existing: String
    var fontSize: CGFloat

    var body: some View {
        Group {
            if live.transcript.isEmpty, existing.isEmpty {
                Text(L(listening ? "ask.voice.waiting" : "ask.voice.recognizing"))
                    .foregroundStyle(StudioTheme.textTertiary)
            } else if live.transcript.isEmpty {
                Text(existing).foregroundStyle(StudioTheme.textPrimary)
            } else {
                Text(existing + live.transcript.confirmed).foregroundColor(StudioTheme.textPrimary)
                    + Text(live.transcript.pending)
                    .foregroundColor(listening ? StudioTheme.textTertiary : StudioTheme.textSecondary)
            }
        }
        .font(.system(size: fontSize))
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.leading, AskComposerTextView.lineFragmentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.voice.liveText")
    }
}

/// "0:04": time since listening began.
struct AskVoiceElapsed: View {
    @ObservedObject var live: AskVoiceLive

    var body: some View {
        if let startedAt = live.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(AskLauncherContext.elapsed(context.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .accessibilityHidden(true)
        }
    }
}

/// Bars for the most recent input levels, newest on the right.
struct AskLevelWaveform: View {
    var levels: [Float]
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maximumHeight: CGFloat = 44
    static func barHeight(level: Float) -> CGFloat {
        4 + (maximumHeight - 4) * CGFloat(min(1, max(0, level.isFinite ? level : 0)))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(active ? AskTheme.accent : StudioTheme.textTertiary.opacity(0.5))
                    .frame(width: 3, height: active ? Self.barHeight(level: level) : 4)
            }
        }
        .frame(height: Self.maximumHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// Takes the launcher's results area while recording, at the same height so
/// the panel does not jump: the waveform, how to finish or cancel, a few things
/// to say, and the context that goes along once the words are in.
struct AskVoicePanel: View {
    @ObservedObject var live: AskVoiceLive
    var listening: Bool
    var height: CGFloat
    var token: AskLauncherContext.Token?

    /// Below the starting points' height, so recording in an empty launcher keeps its size.
    static let minimumHeight: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: 10) {
                AskLevelWaveform(levels: live.levels, active: listening)
                Text(L(listening ? "ask.voice.panel.hint" : "ask.voice.panel.transcribing"))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                if listening {
                    Text(L("ask.voice.panel.examples"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                if let token, (token.hasSource && !token.sourceOff) || token.screenshot == .attached {
                    contextNote(token)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.voice.panel")
    }

    private func contextNote(_ token: AskLauncherContext.Token) -> some View {
        HStack(spacing: 6) {
            if let bundle = token.bundleID, let icon = AskContextChips.appIcon(bundle), !token.sourceOff {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            if token.screenshot == .attached {
                Image(systemName: "display").font(.system(size: 10))
            }
            Text(L("ask.voice.panel.context"))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(AskTheme.hoverFill.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(AskTheme.border, lineWidth: 0.5))
    }
}
