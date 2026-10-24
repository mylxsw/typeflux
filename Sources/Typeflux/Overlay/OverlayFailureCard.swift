import SwiftUI

/// The auto-dismiss timer of a failure without actions. It pauses while the pointer is over the card.
struct OverlayFailureCountdown: Equatable {
    let total: TimeInterval
    var remaining: TimeInterval
    /// When the timer last started running; nil while paused.
    var resumedAt: Date?

    init(total: TimeInterval, startedAt: Date) {
        self.total = total
        remaining = total
        resumedAt = startedAt
    }

    var isPaused: Bool { resumedAt == nil }

    func remaining(at date: Date) -> TimeInterval {
        guard let resumedAt else { return remaining }
        return max(0, remaining - date.timeIntervalSince(resumedAt))
    }

    /// The share of the countdown left, from 1 down to 0.
    func fraction(at date: Date) -> CGFloat {
        total > 0 ? CGFloat(remaining(at: date) / total) : 0
    }

    func paused(at date: Date) -> OverlayFailureCountdown {
        var countdown = self
        countdown.remaining = remaining(at: date)
        countdown.resumedAt = nil
        return countdown
    }

    func resumed(at date: Date) -> OverlayFailureCountdown {
        guard isPaused else { return self }
        var countdown = self
        countdown.resumedAt = date
        return countdown
    }
}

/// Where each failure action goes in the footer: the first text action becomes a link on the left,
/// the others become pills with the primary ones last. With room to spare the left side reminds
/// the user of the action key instead.
struct OverlayFailureFooterLayout: Equatable {
    var linkIndex: Int?
    var pillIndices: [Int]
    var hint: String?

    init(actions: [OverlayFailureAction]) {
        let link = actions.firstIndex { $0.style == .text }
        let pills = actions.indices.filter { $0 != link }
        linkIndex = link
        pillIndices = pills.filter { actions[$0].style != .primary } + pills.filter { actions[$0].style == .primary }
        if link != nil || pills.count > 1 {
            // Two buttons need the whole row; the keys still work without the hint.
            hint = nil
        } else if let first = actions.first {
            // Return runs the first action (`OverlayController.handleKeyCode`).
            hint = L("overlay.failure.hint.primary", first.title)
        } else {
            hint = nil
        }
    }
}

/// The failure card below the bottom capsules: a tone disc, the title and a close button, the
/// message, then the actions. Rises out of the capsule's place.
struct OverlayFailureCard: View {
    static let width: CGFloat = 360
    static let cornerRadius: CGFloat = 22

    let title: String
    let message: String
    let tone: OverlayFailureTone
    let actions: [OverlayFailureAction]
    let countdown: OverlayFailureCountdown?
    let onAction: (Int) -> Void
    let onDismiss: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OverlayFailureDisc(tone: tone)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                OverlayFailureCloseButton(action: onDismiss)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                Text(message)
                    .font(.system(size: 12.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(Color.white.opacity(0.74))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 74)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 46)
            .padding(.trailing, 18)
            .padding(.top, 8)
            .padding(.bottom, actions.isEmpty ? 12 : 0)

            if !actions.isEmpty {
                OverlayFailureFooter(actions: actions, onAction: onAction)
                    .frame(minHeight: 26)
                    .padding(.leading, 46)
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(
            LiquidGlassShapeBackground(shape: shape, cornerRadius: Self.cornerRadius,
                                       tintOpacity: 0.06, strokeOpacity: 0, lineWidth: 0.5)
                .overlay(shape.fill(Color(red: 0.055, green: 0.055, blue: 0.075).opacity(0.62)))
        )
        .overlay(alignment: .bottomLeading) {
            if let countdown { OverlayFailureCountdownBar(countdown: countdown) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.32), radius: 22, x: 0, y: 14)
        .environment(\.colorScheme, .dark)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .bottom)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }
}

/// The footer shared by every failure: a link or key hint on the left, pills on the right.
struct OverlayFailureFooter: View {
    let actions: [OverlayFailureAction]
    /// Top skins have no close button in their header, so they add a close pill here.
    var onClose: (() -> Void)?
    let onAction: (Int) -> Void

    var body: some View {
        let layout = OverlayFailureFooterLayout(actions: actions)
        HStack(spacing: 6) {
            if let index = layout.linkIndex {
                Button(action: { onAction(index) }) {
                    Text(actions[index].title)
                        .font(.system(size: 12))
                        .underline(color: Color.white.opacity(0.25))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else if onClose == nil, let hint = layout.hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onClose {
                VoiceCapsulePillButton(title: L("voiceCapsule.action.close"), prominent: false, action: onClose)
            }
            ForEach(layout.pillIndices, id: \.self) { index in
                let action = actions[index]
                VoiceCapsulePillButton(title: action.title, prominent: action.style == .primary,
                                       systemImage: action.trailingSystemImage) { onAction(index) }
            }
        }
    }
}

/// A 22pt disc that names the kind of failure: orange for errors, amber for timeouts, blue for billing.
struct OverlayFailureDisc: View {
    let tone: OverlayFailureTone

    var body: some View {
        let (color, symbol): (Color, String) = switch tone {
        case .error: (Color(red: 0.82, green: 0.33, blue: 0.10), "exclamationmark")
        case .timeout: (Color(red: 0.79, green: 0.54, blue: 0.08), "clock")
        case .billing: (Color(red: 0.18, green: 0.45, blue: 0.91), "creditcard")
        }
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color))
            .shadow(color: color.opacity(0.45), radius: 6)
            .accessibilityHidden(true)
    }
}

/// A quiet ✕ that brightens under the pointer.
private struct OverlayFailureCloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovered ? 1 : 0.45))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(L("voiceCapsule.action.close"))
    }
}

/// A 2pt line along the bottom edge that runs out when the failure leaves on its own.
struct OverlayFailureCountdownBar: View {
    let countdown: OverlayFailureCountdown
    @Environment(\.overlayAnimationsActive) private var animationsActive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: countdown.isPaused || !animationsActive)) { context in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: geo.size.width * countdown.fraction(at: context.date))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
