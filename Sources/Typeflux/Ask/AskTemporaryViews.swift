import SwiftUI

/// What the title bar's compose button offers: one row per kind of conversation,
/// each with what it means and its shortcut (the shortcuts start it directly).
struct AskNewConversationMenu: View {
    @ObservedObject var model: AskConversationModel
    var close: () -> Void

    static let width: CGFloat = 300

    struct Item: Equatable {
        var kind: AskStorageKind
        var shortcut: String
        var enabled: Bool
    }

    /// ⌘N starts the default kind; signed out there is no Cloud, so this Mac is the default.
    static func items(signedIn: Bool, privateByDefault: Bool) -> [Item] {
        let localDefault = !signedIn || privateByDefault
        return [Item(kind: .cloud, shortcut: localDefault ? "" : "⌘N", enabled: signedIn),
                Item(kind: .local, shortcut: localDefault ? "⌘N" : "⇧⌘N", enabled: true),
                Item(kind: .temporary, shortcut: "⌥⌘N", enabled: true)]
    }

    static func titleKey(_ kind: AskStorageKind) -> String {
        switch kind {
        case .cloud: "ask.new.cloud"
        case .local: "ask.storage.newLocal"
        case .temporary: "ask.temporary.new"
        }
    }

    static func detailKey(_ kind: AskStorageKind, signedIn: Bool) -> String {
        kind == .cloud && !signedIn ? "ask.new.cloud.signedOut" : kind.detailKey
    }

    /// Starts the chosen kind; the model asks first when that leaves a temporary chat.
    static func start(_ kind: AskStorageKind, model: AskConversationModel) {
        switch kind {
        case .cloud: model.newConversation(storesLocally: false)
        case .local: model.newConversation(storesLocally: true)
        case .temporary: model.newConversation(temporary: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.items(signedIn: model.isSignedIn, privateByDefault: model.commandSources.privateByDefault()),
                    id: \.kind) { item in
                Button {
                    close()
                    Self.start(item.kind, model: model)
                } label: { row(item) }
                .buttonStyle(AskNewConversationRowStyle())
                .disabled(!item.enabled)
                .accessibilityIdentifier("ask.workspace.new." + String(describing: item.kind))
            }
        }
        .padding(5)
        .frame(width: Self.width, alignment: .leading)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AskLocalModeCard.tint(item.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(Self.titleKey(item.kind)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L(Self.detailKey(item.kind, signedIn: model.isSignedIn)))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .opacity(item.enabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

private struct AskNewConversationRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((configuration.isPressed ? AskTheme.pressFill : hovering ? AskTheme.hoverFill : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
    }
}

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
            .overlay(Capsule().strokeBorder(AskTheme.temporaryTint.opacity(0.55),
                                            style: StrokeStyle(lineWidth: 0.8, dash: AskTheme.temporaryDash)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("ask.storage.temporary.detail"))
        .accessibilityLabel(L("ask.storage.temporary"))
        .accessibilityHint(L("ask.storage.help"))
        .accessibilityIdentifier("ask.workspace.temporary")
        .askMenu(isPresented: $presented, glass: true) {
            AskLocalModeCard(status: .make(model: model, signedIn: model.isSignedIn),
                             onOpenSearchSettings: {
                                 presented = false
                                 model.onOpenSettings?(.agent)
                             }, onSignIn: {
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

/// Pinned above history while a temporary conversation is open or being started:
/// it is never listed there, so this row is where the sidebar shows the selection.
struct AskTemporaryHistoryRow: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: AskStorageKind.temporary.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AskTheme.temporaryTint)
            Text(L("ask.temporary.title"))
                .font(.system(size: 13))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(L("ask.temporary.inProgress"))
                .font(.system(size: 11))
                .foregroundStyle(AskTheme.temporaryTint)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(AskTheme.temporaryFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(AskTheme.temporaryTint.opacity(0.55),
                          style: StrokeStyle(lineWidth: 1, dash: AskTheme.temporaryDash)))
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.history.temporary")
        .help(L("ask.temporary.fact.history"))
    }
}

/// Under the new-conversation title: what a temporary conversation does not keep.
struct AskTemporaryEmptyHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: AskStorageKind.temporary.symbol)
            Text(L("ask.temporary.empty"))
        }
        .font(.system(size: 12.5))
        .foregroundStyle(AskTheme.temporaryTint)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(AskTheme.temporaryFill, in: Capsule())
        .overlay(Capsule().strokeBorder(AskTheme.temporaryTint.opacity(0.5),
                                        style: StrokeStyle(lineWidth: 0.8, dash: AskTheme.temporaryDash)))
        .accessibilityIdentifier("ask.empty.temporary")
    }
}
