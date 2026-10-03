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

/// A key drawn as a small key cap, e.g. "⌘K" in the sidebar's search field.
struct AskKeyHint: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AskTheme.separator, lineWidth: 0.5))
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
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium))
            }
            Text(title).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.leading, thumbnail == nil ? 9 : 4)
        .padding(.trailing, 9)
        .frame(height: 26)
        .background(AskTheme.hoverFill, in: Capsule())
        .overlay(Capsule().strokeBorder(AskTheme.separator, lineWidth: 0.5))
        .contentShape(Capsule())
        .accessibilityLabel(title)
    }
}

/// The keyboard hint under the workspace composer. It fades in while the
/// editor has focus and keeps its height otherwise, so the card never moves.
struct AskComposerHint: View {
    @ObservedObject var voice: AskVoiceInput
    let contextID: String
    let settings: SettingsStore
    @State private var voiceKey = "Fn"

    static func text(voiceKey: String) -> String { L("ask.composer.hint", voiceKey) }

    var body: some View {
        Text(Self.text(voiceKey: voiceKey))
            .font(.system(size: 11))
            .foregroundStyle(StudioTheme.textTertiary)
            .lineLimit(1)
            .frame(height: AskMetrics.composerHintHeight - 8)
            .opacity(voice.focusedContext == contextID ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: voice.focusedContext == contextID)
            .accessibilityHidden(true)
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: .hotkeySettingsDidChange)) { _ in refresh() }
    }

    private func refresh() {
        voiceKey = settings.activationHotkey.map(HotkeyFormat.display) ?? "Fn"
    }
}

/// The hairline between groups in a composer menu.
struct AskPopoverDivider: View {
    var body: some View {
        Rectangle().fill(AskTheme.separator).frame(height: 0.5)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
    }
}
