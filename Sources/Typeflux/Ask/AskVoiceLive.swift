import Foundation

/// What the microphone hears while a composer records: recent input levels for
/// the waveform and the words recognised so far. It lives apart from
/// `AskVoiceInput` so only the recording views redraw as it changes, never the
/// whole composer.
@MainActor
final class AskVoiceLive: ObservableObject {
    static let barCount = 32
    /// Levels are published at most this often; the recorder reports every buffer.
    static let levelInterval: TimeInterval = 0.05

    @Published private(set) var levels: [Float] = AskVoiceLive.silence
    @Published private(set) var transcript = AskVoiceTranscript()
    /// When listening began, for the elapsed time; nil while idle.
    @Published private(set) var startedAt: Date?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastLevelAt: TimeInterval = -.infinity
    private var pendingPeak: Float = 0

    static let silence = [Float](repeating: 0, count: barCount)

    func reset(startedAt: Date? = nil) {
        if levels != Self.silence { levels = Self.silence }
        if !transcript.isEmpty { transcript = AskVoiceTranscript() }
        if self.startedAt != startedAt { self.startedAt = startedAt }
        lastLevelAt = -.infinity
        pendingPeak = 0
    }

    /// Takes a normalised input level (0...1). The loudest level since the last
    /// published bar becomes the next bar, so short syllables are not lost.
    func receive(level: Float) {
        let value = level.isFinite ? min(1, max(0, level)) : 0
        pendingPeak = max(pendingPeak, value)
        let time = now()
        guard time - lastLevelAt >= Self.levelInterval else { return }
        lastLevelAt = time
        levels = Array(levels.dropFirst()) + [pendingPeak]
        pendingPeak = 0
    }

    func receive(text: String, isFinal: Bool) {
        var next = transcript
        next.apply(text, isFinal: isFinal)
        if next != transcript { transcript = next }
    }
}

/// Recognised speech while recording: the part the recogniser has committed and
/// the latest guess after it, which may still change.
struct AskVoiceTranscript: Equatable {
    /// The latest recognised text, committed part included.
    private(set) var text = ""
    /// Text a final result has committed.
    private(set) var stable = ""

    var isEmpty: Bool { text.isEmpty }
    /// The committed start of `text`.
    var confirmed: String { text.hasPrefix(stable) ? stable : "" }
    /// Words after the committed start that may still change.
    var pending: String { String(text.dropFirst(confirmed.count)) }

    mutating func apply(_ value: String, isFinal: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = trimmed
        if isFinal { stable = trimmed }
    }
}
