import SwiftUI

/// The header's mark for the temporary conversation, where others show credits or
/// "Only on this Mac". A click explains it and offers to keep or end it.
struct AskTemporaryChip: View {
    @ObservedObject var model: AskConversationModel
    var showsTitle = true
    @Environment(\.interfaceStyle) private var style
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: AskStorageKind.temporary.symbol)
                if showsTitle { Text(L("ask.storage.temporary")) }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(AskTheme.temporaryTint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, style.usesGlass ? 12 : 9)
            .frame(height: style.ask.headerChipHeight)
            .background(AskTheme.temporaryFill, in: Capsule())
            .overlay(Capsule().strokeBorder(AskTheme.temporaryTint.opacity(AskTheme.temporaryEdgeOpacity),
                                            style: StrokeStyle(lineWidth: 0.8, dash: AskTheme.temporaryDash)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("ask.storage.temporary.detail"))
        .accessibilityLabel(L("ask.storage.temporary"))
        .accessibilityHint(L("ask.storage.help"))
        .accessibilityIdentifier("ask.workspace.temporary")
        .askMenu(isPresented: $presented, glass: true) {
            AskObservedContent(model: model) {
                AskLocalModeCard(status: .make(model: model, signedIn: model.isSignedIn),
                             onSignIn: {
                                 presented = false
                                 model.onSignIn()
                             }, onChoose: { kind in
                                 presented = false
                                 model.chooseStorage(kind, launcher: false)
                             }, onKeep: {
                                 presented = false
                                 model.keepTemporaryConversation()
                             }, onEnd: {
                                 presented = false
                                 model.endTemporaryConversation()
                             })
            }
        }
    }
}

/// Pinned above history while a temporary conversation is open or being started:
/// it is never listed there, so this row is where the sidebar shows the selection.
struct AskTemporaryHistoryRow: View {
    var selected = true
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Image(systemName: AskStorageKind.temporary.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AskTheme.temporaryTint)
                    Text(L("ask.temporary.title"))
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.history.temporary.select")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AskTheme.temporaryTint)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("ask.temporary.end"))
            .accessibilityLabel(L("ask.temporary.end"))
            .accessibilityIdentifier("ask.history.temporary.close")
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .background(selected ? AskTheme.temporaryFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(AskTheme.temporaryTint.opacity(selected ? AskTheme.temporaryEdgeOpacity : 0.2),
                          style: StrokeStyle(lineWidth: 1, dash: AskTheme.temporaryDash)))
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.history.temporary")
    }
}
