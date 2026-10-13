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
        case .done: return TypefluxColor.success.color
        case .running: return TypefluxColor.accent.color
        case .attention: return TypefluxColor.warning.color
        case .failed: return TypefluxColor.danger.color
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
/// system's Liquid Glass buttons. Reduce Motion and the classic style, whose
/// controls never moved, keep them still.
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
        @Environment(\.interfaceStyle) private var style

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion && style.usesGlass ? scale : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55),
                           value: configuration.isPressed)
        }
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
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.callout)
                .foregroundStyle(active ? TypefluxColor.success.color
                    : (hovering ? TypefluxColor.label.color : TypefluxColor.tertiaryLabel.color))
                .frame(width: 28, height: 28)
                .background(hovering ? TypefluxColor.label.color.opacity(0.06) : Color.clear,
                            in: style.controlShape(height: 28))
                .contentShape(style.controlShape(height: 28))
        }
        .buttonStyle(AskPressableStyle())
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A key drawn as a small key cap, e.g. "⌘K" in the sidebar's search field.
struct AskKeyHint: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline).fontWeight(.medium)
            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(LegacyAskPalette.keycapSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(TypefluxColor.separator.color, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The signed-in user's initials on the design board's violet gradient.
struct AskAvatar: View {
    let name: String
    var size: CGFloat = 26

    /// Up to two initials: the first letters of the first two words, or the
    /// first two characters of a single word.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
        let letters: [Character]
        if words.count >= 2 {
            letters = words.prefix(2).compactMap(\.first)
        } else {
            letters = Array((words.first ?? "").prefix(2))
        }
        return String(letters).uppercased()
    }

    var body: some View {
        Text(verbatim: Self.initials(name))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.369, green: 0.361, blue: 0.902),
                                                Color(red: 0.749, green: 0.353, blue: 0.949)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// What rode with a sent question, as a small capsule above its bubble: a
/// screenshot thumbnail or an icon, then a label.
struct AskSentAttachmentChip: View {
    let title: String
    var thumbnail: NSImage?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 26, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if let systemImage {
                Image(systemName: systemImage).font(.footnote).fontWeight(.medium)
            }
            Text(title).lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
        .padding(.leading, thumbnail == nil ? 9 : 4)
        .padding(.trailing, 9)
        .frame(height: 26)
        .background(TypefluxColor.label.color.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(TypefluxColor.separator.color, lineWidth: 0.5))
        .contentShape(Capsule())
        .accessibilityLabel(title)
    }
}

/// The hairline between groups in a composer menu.
struct AskPopoverDivider: View {
    var body: some View {
        Rectangle().fill(TypefluxColor.separator.color).frame(height: 0.5)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
    }
}
