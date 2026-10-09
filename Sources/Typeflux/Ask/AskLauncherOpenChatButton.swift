import SwiftUI

struct AskLauncherOpenChatButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "macwindow")
                .font(.system(size: 16, weight: .medium))
                .frame(width: AskSendButton.size, height: AskSendButton.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTheme.textSecondary)
        .disabled(!enabled)
        .help(enabled ? L("ask.openChat.hint") : L("ask.openChat.wait"))
        .accessibilityLabel(L("ask.openChat"))
        .accessibilityIdentifier("ask.launcher.openChat")
        .modifier(AskLauncherShortcutBadge(key: "o", leadingInset: 24, topInset: -5))
    }
}
