import SwiftUI

/// Content selects the action; readiness only enables it, never changes its meaning.
enum AskLauncherChatAction: Equatable {
    case openChat, askAI
    case execute(String)

    static func resolve(draft: AskDraft, pluginOffersAskAI: Bool = false, loadingAttachments: Bool = false) -> Self {
        draft.hasChatInput || pluginOffersAskAI || loadingAttachments ? .askAI : .openChat
    }

    /// Badges appear while Command is held; execution itself has no Command shortcut.
    var shortcut: String? {
        switch self {
        case .openChat: "O"
        case .askAI: "↩"
        case .execute: nil
        }
    }
    var title: String {
        switch self {
        case .openChat: L("ask.openChat")
        case .askAI: L("ask.quick.askAI")
        case let .execute(title): title
        }
    }
    var hint: String { title + " ↩" + (self == .askAI ? " · ⌘↩" : "") }
    var symbol: String {
        switch self {
        case .openChat: "bubble.left"
        case .askAI: "arrow.up"
        case .execute: "return"
        }
    }
}
/// The primary action keeps the original accessibility identifier for existing clients.
///
/// One view for every mode, so a change of mode or readiness animates in place:
/// the circle fills or clears, the symbol cross-fades, and nothing is swapped for
/// a different control. The launcher card disables animations for everything
/// else, so this button opts back in for its own content only.
struct AskLauncherOpenChatButton: View {
    var mode: AskLauncherChatAction = .openChat
    var enabled: Bool
    /// Only waiting for the newest input's results: drawn as ready, so the button
    /// does not dim and brighten again on every keystroke, but not yet clickable.
    var waiting = false
    var disabledReason: String?
    var tint: Color = AskTheme.accent
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let transition: Animation = .easeOut(duration: 0.18)

    /// How the button looks; `enabled` alone decides whether it acts.
    private var looksEnabled: Bool {
        enabled || waiting
    }

    private var lit: Bool {
        mode == .askAI && looksEnabled
    }

    private var fill: Color {
        if lit {
            return tint
        }
        return mode == .askAI ? AskTheme.hoverFill : AskTheme.hoverFill.opacity(0)
    }

    private var foreground: Color {
        switch mode {
        case .askAI: lit ? .white : StudioTheme.textTertiary
        case .openChat: StudioTheme.textSecondary
        case .execute: AskVoiceButton.Appearance.iconColor(phase: .idle, hovered: looksEnabled && hovered)
        }
    }

    private var font: Font {
        switch mode {
        case .askAI: .system(size: 16, weight: .semibold)
        case .openChat: .system(size: 16, weight: .medium)
        case .execute: .system(size: 15, weight: .regular)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                // The lit drop's highlight, as on the workspace send button.
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.32), .clear],
                                         center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: 22))
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
                Image(systemName: mode.symbol)
                    .font(font)
                    .foregroundStyle(foreground)
                    // A new symbol replaces the old one in place instead of cutting to it.
                    .id(mode.symbol)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            .frame(width: AskSendButton.size, height: AskSendButton.size)
            .contentShape(Circle())
        }
        .buttonStyle(AskPressableStyle())
        .shadow(color: lit ? tint.opacity(0.5) : tint.opacity(0), radius: 9, y: 3)
        .opacity(mode != .openChat && mode != .askAI && !looksEnabled ? 0.45 : 1)
        .onHover { hovered = $0 }
        .disabled(!enabled)
        .transaction { transaction in
            transaction.disablesAnimations = false
            transaction.animation = reduceMotion ? nil : Self.transition
        }
        .help(enabled ? mode.hint : disabledReason ?? L("ask.launcher.action.unavailable"))
        .accessibilityLabel(mode.title)
        .accessibilityIdentifier("ask.launcher.openChat")
        .accessibilityValue(mode.symbol)
        .accessibilityHint(enabled ? mode.hint : disabledReason ?? L("ask.launcher.action.unavailable"))
        .modifier(AskLauncherShortcutBadge(key: looksEnabled ? mode.shortcut : nil, leadingInset: 24, topInset: -5))
    }
}
