import AppKit
import SwiftUI

/// The run's state as a small dot beside the title's summary. A running run
/// breathes; Reduce Motion keeps it still.
struct AskRunToneDot: View {
    let tone: AskRunTone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    static func color(_ tone: AskRunTone) -> Color {
        switch tone {
        case .done: return StudioTheme.success
        case .running: return AskTheme.accent
        case .attention: return StudioTheme.warning
        case .failed: return StudioTheme.danger
        }
    }

    static func pulses(_ tone: AskRunTone, reduceMotion: Bool) -> Bool { tone == .running && !reduceMotion }

    var body: some View {
        Circle()
            .fill(Self.color(tone))
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .shadow(color: tone == .running ? Self.color(tone).opacity(0.7) : .clear, radius: 3)
            .onAppear { animate() }
            .onChange(of: tone) { _ in animate() }
            .accessibilityHidden(true)
    }

    private func animate() {
        guard Self.pulses(tone, reduceMotion: reduceMotion) else { dim = false; return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// Glass controls give way under the pointer with a short spring, like the
/// system's Liquid Glass buttons. Reduce Motion keeps them still.
struct AskPressableStyle: ButtonStyle {
    static let pressedScale: CGFloat = 0.92
    /// For wide rows, where a deep press would shift the text noticeably.
    static let subtle = AskPressableStyle(scale: 0.98)

    var scale: CGFloat = pressedScale

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(configuration: configuration, scale: scale)
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55),
                           value: configuration.isPressed)
        }
    }
}

/// An SF Symbol button inside the header's actions capsule.
struct AskHeaderIconButton: View {
    var symbol: String
    var label: String
    var shortcut: String?
    var active = false
    var action: () -> Void
    @State private var hovering = false

    static func ink(active: Bool, hovering: Bool) -> Color {
        if active { return AskTheme.accent }
        return hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(AskHeaderIconButton.ink(active: active, hovering: hovering))
                .frame(width: 30, height: 28)
                .background(hovering || active ? AskTheme.hoverFill : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(AskPressableStyle())
        .onHover { hovering = $0 }
        .help(AskTitleBarButton.help(label: label, shortcut: shortcut))
        .accessibilityLabel(label)
    }
}

/// A drawn line icon (usage, trash) inside the header's actions capsule.
struct AskHeaderLineButton: View {
    var kind: AskLineGlyph.Kind
    var label: String
    var active = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            AskLineIcon(kind: kind, size: 15)
                .foregroundStyle(AskHeaderIconButton.ink(active: active, hovering: hovering))
                .frame(width: 30, height: 28)
                .background(hovering || active ? AskTheme.hoverFill : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(AskPressableStyle())
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The empty state's mark: a glass orb whose colours slowly turn, in place of
/// a flat tile. Reduce Motion holds it still.
struct AskConversationOrb: View {
    var size: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let colors: [Color] = [
        AskTheme.accent,
        Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 1.0, green: 0.22, blue: 0.37),
        Color(red: 1.0, green: 0.62, blue: 0.04),
        AskTheme.accent
    ]

    /// One turn every 12 seconds.
    static func angle(at date: Date) -> Angle {
        .degrees(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) * 30)
    }

    var body: some View {
        Group {
            if reduceMotion {
                orb(angle: .zero)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    orb(angle: Self.angle(at: context.date))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func orb(angle: Angle) -> some View {
        ZStack {
            Circle().fill(AngularGradient(colors: Self.colors, center: .center, angle: angle))
            // The lens: a soft white bloom toward the light, a shaded lower rim.
            Circle().fill(RadialGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                                         center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: size * 0.32))
            Circle().fill(RadialGradient(colors: [Color.clear, Color.black.opacity(0.22)],
                                         center: .center, startRadius: size * 0.3, endRadius: size * 0.52))
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: AskTheme.accent.opacity(0.4), radius: size * 0.22, y: size * 0.12)
    }
}

/// An icon-only action under an answer. The words live in the tooltip and the
/// accessibility label, so the strip stays as quiet as the design's.
struct AskIconGhostButton: View {
    var label: String
    var systemImage: String
    var active = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 12.5))
                .foregroundStyle(active ? StudioTheme.success
                    : (hovering ? StudioTheme.textPrimary : StudioTheme.textTertiary))
                .frame(width: 28, height: 28)
                .background(hovering ? AskTheme.hoverFill : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(AskPressableStyle())
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
