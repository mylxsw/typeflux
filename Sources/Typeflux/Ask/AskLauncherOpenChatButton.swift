import SwiftUI

/// Content selects the action; readiness only enables it, never changes its meaning.
enum AskLauncherChatAction: Equatable {
    case openChat, askAI

    static func resolve(draft: AskDraft, pluginOffersAskAI: Bool = false, loadingAttachments: Bool = false) -> Self {
        draft.hasChatInput || pluginOffersAskAI || loadingAttachments ? .askAI : .openChat
    }

    var shortcut: String { self == .askAI ? "↩" : "O" }
    var title: String { L(self == .askAI ? "ask.quick.askAI" : "ask.openChat") }
    var hint: String { self == .askAI ? title + " ⌘↩" : L("ask.openChat.hint") }
}

struct AskLauncherOpenChatButton: View {
    var mode: AskLauncherChatAction = .openChat
    var enabled: Bool
    var tint: Color = AskTheme.accent
    var action: () -> Void

    var body: some View {
        Group {
            if mode == .askAI {
                AskSendButton(enabled: enabled, tint: tint, animatesEmphasis: false, action: action)
            } else {
                Button(action: action) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: AskSendButton.size, height: AskSendButton.size)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textSecondary)
                .disabled(!enabled)
            }
        }
        .help(mode.hint)
        .accessibilityLabel(mode.title)
        .accessibilityIdentifier("ask.launcher.openChat")
        .modifier(AskLauncherShortcutBadge(key: enabled ? mode.shortcut : nil, leadingInset: 24, topInset: -5))
    }
}
