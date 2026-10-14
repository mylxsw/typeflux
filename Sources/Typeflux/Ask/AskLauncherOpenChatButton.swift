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
struct AskLauncherOpenChatButton: View {
    var mode: AskLauncherChatAction = .openChat
    var enabled: Bool
    var disabledReason: String?
    var tint: Color = AskTheme.accent
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Group {
            if mode == .askAI {
                AskSendButton(enabled: enabled, tint: tint, animatesEmphasis: false,
                              symbol: mode.symbol, action: action)
            } else {
                Button(action: action) {
                    Image(systemName: mode.symbol)
                        .font(mode == .openChat ? .system(size: 16, weight: .medium)
                              : .system(size: 15, weight: .regular))
                        .frame(width: AskSendButton.size, height: AskSendButton.size)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(mode == .openChat ? StudioTheme.textSecondary
                    : AskVoiceButton.Appearance.iconColor(phase: .idle, hovered: enabled && hovered))
                .opacity(mode == .openChat || enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .disabled(!enabled)
            }
        }
        .help(enabled ? mode.hint : disabledReason ?? L("ask.launcher.action.unavailable"))
        .accessibilityLabel(mode.title)
        .accessibilityIdentifier("ask.launcher.openChat")
        .accessibilityValue(mode.symbol)
        .accessibilityHint(enabled ? mode.hint : disabledReason ?? L("ask.launcher.action.unavailable"))
        .modifier(AskLauncherShortcutBadge(key: enabled ? mode.shortcut : nil, leadingInset: 24, topInset: -5))
    }
}
