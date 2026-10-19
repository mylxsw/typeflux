import SwiftUI

/// The capsule states the corner card and the notch island draw.
enum VoiceCapsulePhase: Equatable {
    case listening(handsFree: Bool)
    case processing
    case completed
    case failure

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    var showsRecordingControls: Bool { self == .listening(handsFree: true) }

    /// The corner card's hover controls. Holding the shortcut confirms on release, so it only
    /// offers cancel; a finished or failed capsule has nothing to act on from the header.
    var cardControls: [VoiceCapsuleCardControl] {
        switch self {
        case .listening(handsFree: true): [.cancel, .confirm]
        case .listening(handsFree: false), .processing: [.cancel]
        case .completed, .failure: []
        }
    }
}

enum VoiceCapsuleCardControl: Equatable {
    case cancel
    case confirm
}

/// Everything a top-anchored capsule needs to render one frame. The overlay model owns the
/// state; this value keeps the skins free of controller details.
struct VoiceCapsuleSnapshot {
    var phase: VoiceCapsulePhase
    var text: String = ""
    var level: Float = 0
    var progress: CGFloat = 0
    /// Processing or failure title.
    var statusText: String = ""
    /// Failure detail.
    var message: String = ""
    var targetAppName: String?
    var recordingStartedAt: Date?
    var completedCharacterCount: Int = 0
    var expanded = false
    /// Lines the transcript area shows (1...3); the window is sized for the same count.
    var transcriptLines = VoiceCapsuleLayout.maxTranscriptLines
    /// The pointer is over the corner card, so its controls replace the timer.
    var controlsRevealed = false
    var failureActions: [OverlayFailureAction] = []
    var failureAccent = Color(red: 1.0, green: 0.56, blue: 0.28)

    /// Shows the transcript area; a failure always shows its message.
    var showsBody: Bool { expanded || phase == .failure }
}

/// Callbacks shared by both skins.
struct VoiceCapsuleActions {
    var cancel: () -> Void = {}
    var confirm: () -> Void = {}
    var dismiss: () -> Void = {}
    var failureAction: (Int) -> Void = { _ in }
}

/// Short labels shared by both skins, kept here so they can be tested without rendering.
enum VoiceCapsuleCopy {
    static let productName = "Typeflux"

    static func state(for snapshot: VoiceCapsuleSnapshot) -> String {
        switch snapshot.phase {
        case let .listening(handsFree):
            handsFree ? L("voiceCapsule.state.handsFree") : L("overlay.recording.listening")
        case .processing:
            snapshot.statusText.isEmpty ? L("overlay.processing.thinking") : snapshot.statusText
        case .completed:
            L("voiceCapsule.state.completed")
        case .failure:
            snapshot.statusText.isEmpty ? L("overlay.failure.title") : snapshot.statusText
        }
    }

    /// The corner card's second line: state, then target app and details, separated by middle dots.
    static func subtitle(for snapshot: VoiceCapsuleSnapshot) -> String {
        var parts = [state(for: snapshot)]
        if let app = snapshot.targetAppName, !app.isEmpty, snapshot.phase != .failure {
            parts.append(app)
        }
        if snapshot.phase == .completed, snapshot.completedCharacterCount > 0 {
            parts.append(L("voiceCapsule.state.characterCount", snapshot.completedCharacterCount))
        }
        return parts.joined(separator: " · ")
    }

    static func percent(_ progress: CGFloat) -> String {
        "\(Int((max(0, min(1, progress)) * 100).rounded()))%"
    }

    static func hint(for phase: VoiceCapsulePhase) -> String {
        phase.showsRecordingControls ? L("voiceCapsule.hint.handsFree") : L("voiceCapsule.hint.hold")
    }
}

/// The Typeflux orb: a slowly turning color field that swells with the input level,
/// then turns green or orange for the result.
struct VoiceCapsuleOrb: View {
    let phase: VoiceCapsulePhase
    let level: Float
    let diameter: CGFloat
    /// Rings that spread with the voice; the corner card's only level indicator.
    var showsRipples = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let colors: [Color] = [
        Color(red: 0.31, green: 0.53, blue: 1.0), Color(red: 0.61, green: 0.36, blue: 1.0),
        Color(red: 1.0, green: 0.44, blue: 0.68), Color(red: 1.0, green: 0.69, blue: 0.36),
        Color(red: 0.27, green: 0.83, blue: 1.0), Color(red: 0.31, green: 0.53, blue: 1.0)
    ]

    /// Maps the recorder level (0...1, quiet below 0.1) to the orb's response.
    static func response(for level: Float) -> CGFloat {
        guard !level.isNaN else { return 0 }
        return max(0, min(1, (CGFloat(level) - 0.1) / 0.6))
    }

    var body: some View {
        let animates = !reduceMotion && (phase.isListening || phase == .processing)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            orb(angle: animates ? angle(at: context.date) : .zero)
        }
        .frame(width: diameter, height: diameter)
        .background { if showsRipples && !reduceMotion { ripples } }
        .accessibilityHidden(true)
    }

    /// Scale and opacity of the inner and outer ripple for a recorder level.
    static func ripple(for level: Float) -> (inner: (scale: CGFloat, opacity: Double), outer: (scale: CGFloat, opacity: Double)) {
        let response = Self.response(for: level)
        return ((1 + 0.32 * response, Double(0.9 * response)), (1 + 0.6 * response, Double(0.45 * response)))
    }

    @ViewBuilder
    private var ripples: some View {
        if phase.isListening {
            let ripple = Self.ripple(for: level)
            ZStack {
                Circle().strokeBorder(Color(red: 0.59, green: 0.55, blue: 1.0).opacity(0.55), lineWidth: 1.5)
                    .scaleEffect(ripple.inner.scale).opacity(ripple.inner.opacity)
                Circle().strokeBorder(Color(red: 0.59, green: 0.55, blue: 1.0).opacity(0.55), lineWidth: 1.5)
                    .scaleEffect(ripple.outer.scale).opacity(ripple.outer.opacity)
            }
            .animation(.linear(duration: 0.09), value: level)
        }
    }

    private func angle(at date: Date) -> Angle {
        let period = phase == .processing ? 1.1 : 3.4
        let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return .degrees(turn * 360)
    }

    private func orb(angle: Angle) -> some View {
        let response = phase.isListening ? Self.response(for: level) : 0
        return ZStack {
            Circle().fill(Color(red: 0.035, green: 0.035, blue: 0.07))
            switch phase {
            case .completed:
                Circle().fill(Color(red: 0.12, green: 0.62, blue: 0.30))
                Image(systemName: "checkmark").font(.system(size: diameter * 0.42, weight: .bold))
                    .foregroundStyle(Color.white)
            case .failure:
                Circle().fill(Color(red: 0.76, green: 0.25, blue: 0.05))
                Image(systemName: "exclamationmark").font(.system(size: diameter * 0.44, weight: .bold))
                    .foregroundStyle(Color.white)
            case .listening, .processing:
                AngularGradient(colors: Self.colors, center: .center, angle: angle)
                    .scaleEffect(0.62 + 0.42 * response)
                    .blur(radius: diameter * 0.17)
                    .opacity(0.95)
                RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: UnitPoint(x: 0.34, y: 0.28),
                               startRadius: 0, endRadius: diameter * 0.42)
                RadialGradient(colors: [.clear, Color.black.opacity(0.4)], center: .center,
                               startRadius: diameter * 0.26, endRadius: diameter * 0.5)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
        .shadow(color: Color(red: 0.48, green: 0.46, blue: 1.0).opacity(0.2 + 0.55 * response),
                radius: 2 + 9 * response)
    }
}

/// Keeps the newest transcript lines in view inside a fixed number of lines.
struct VoiceCapsuleTranscript: View {
    let text: String
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let lineCount: Int
    let placeholder: String
    private let bottomID = "voice-capsule-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? placeholder : text)
                        .font(.system(size: fontSize, weight: .regular))
                        .lineSpacing(max(0, lineHeight - fontSize * 1.2))
                        .foregroundStyle(Color.white.opacity(text.isEmpty ? 0.45 : 0.96))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 1).id(bottomID)
                }
            }
            .frame(height: lineHeight * CGFloat(lineCount))
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: text) { _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Round cancel / confirm buttons matching the bottom capsule's controls.
struct VoiceCapsuleRoundButton: View {
    let systemName: String
    let inverted: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(Circle().fill(inverted ? Color.white.opacity(0.94) : Color.white.opacity(0.12)))
                .overlay(Circle().stroke(Color.white.opacity(inverted ? 0.46 : 0.22), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Compact text buttons for failure actions and the island's footer.
struct VoiceCapsulePillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.white.opacity(prominent ? 0 : 0.2), lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A determinate ring for the island's compact processing state.
struct VoiceCapsuleProgressRing: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .animation(.linear(duration: 0.06), value: progress)
        .accessibilityHidden(true)
    }
}

/// A 2pt gradient bar along a capsule's bottom edge while processing.
struct VoiceCapsuleProgressBar: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 1.0), Color(red: 0.75, green: 0.52, blue: 0.99)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * max(0, min(1, progress)))
                .clipShape(Capsule())
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.06), value: progress)
        .accessibilityHidden(true)
    }
}

/// The failure footer: the controller's actions plus a close button.
struct VoiceCapsuleFailureActions: View {
    let snapshot: VoiceCapsuleSnapshot
    let actions: VoiceCapsuleActions

    var body: some View {
        HStack(spacing: 6) {
            VoiceCapsulePillButton(title: L("voiceCapsule.action.close"), prominent: false, action: actions.dismiss)
            ForEach(Array(snapshot.failureActions.enumerated()), id: \.offset) { index, action in
                VoiceCapsulePillButton(title: action.title, prominent: action.isRetry || action.style == .primary) {
                    actions.failureAction(index)
                }
            }
        }
    }
}
