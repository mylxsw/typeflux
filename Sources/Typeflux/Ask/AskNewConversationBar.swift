import SwiftUI

/// What a new conversation fixes before its first message, under the composer like
/// ChatGPT's project bar (GUL-464): a task's folders and where it is kept.
/// It goes away once the conversation starts; the header then marks what was chosen.
/// Settings that can change mid-conversation (permission, model) stay in the composer.
struct AskNewConversationBar: View {
    @ObservedObject var model: AskConversationModel
    @Environment(\.interfaceStyle) private var style

    /// What the bar's trailing control says about where the conversation is kept.
    enum Storage: Equatable {
        /// Signed in and still open to choose.
        case choice(AskStorageKind)
        /// Signed out: every conversation stays on this Mac.
        case localOnly
        /// Nothing is kept; the menu can switch back to persistent storage.
        case temporary

        var kind: AskStorageKind {
            switch self {
            case let .choice(kind): kind
            case .localOnly: .local
            case .temporary: .temporary
            }
        }
    }

    static func storage(temporary: Bool, signedIn: Bool, local: Bool) -> Storage {
        if temporary { return .temporary }
        guard signedIn else { return .localOnly }
        return .choice(local ? .local : .cloud)
    }

    private var temporary: Bool { model.isTemporaryComposer(launcher: false) }

    var body: some View {
        HStack(spacing: 2) {
            if model.conversationKind(launcher: false) == .work {
                AskWorkFolderButton(model: model)
            }
            Spacer(minLength: 8)
            AskStorageBarControl(model: model,
                                 storage: Self.storage(temporary: temporary, signedIn: model.isSignedIn,
                                                       local: model.storesLocally(launcher: false)))
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(AskTheme.hoverFill.opacity(0.5),
                    in: UnevenRoundedRectangleShape(bottomRadius: 14))
        .overlay(UnevenRoundedRectangleShape(bottomRadius: 14).stroke(AskTheme.border, lineWidth: 0.5))
        // Continuous corners extend about 1.53 radii along the bottom edge.
        // Keep the bar's square top corners inside that edge's straight section.
        .padding(.horizontal, max(14, ceil(style.ask.composerCorner * 1.53)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.newConversation.bar")
    }
}

/// A rectangle rounded only at the bottom, so the bar hangs from the composer card.
/// (`UnevenRoundedRectangle` needs macOS 14.)
struct UnevenRoundedRectangleShape: Shape {
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A quiet text button in the bar: an icon and a word, filled on hover.
struct AskBarButton: View {
    var symbol: String
    var title: String
    var tint: Color? = nil
    var muted = false
    var chevron = false
    var help: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .fixedSize(horizontal: true, vertical: false)
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
                }
            }
            .foregroundStyle(tint ?? (muted ? StudioTheme.textTertiary
                                              : hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(hovering ? AskTheme.hoverFill : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// The task's folders as one button in the bar; its menu adds and removes them.
struct AskWorkFolderButton: View {
    @ObservedObject var model: AskConversationModel
    @State private var presented = false

    var body: some View {
        AskBarButton(symbol: "folder", title: AskWorkEnvironmentButton.title(model.draft), chevron: true,
                     help: L("ask.bar.folders.help")) { presented.toggle() }
            .accessibilityIdentifier("ask.newConversation.folders")
            .askMenu(isPresented: $presented, glass: true) {
                AskObservedContent(model: model) {
                    AskWorkFolderList(model: model) { presented = false }
                        .padding(.vertical, 6)
                        .frame(width: 300, alignment: .leading)
                }
            }
    }
}

/// One menu chooses cloud, local or temporary storage before the first message.
struct AskStorageBarControl: View {
    @ObservedObject var model: AskConversationModel
    let storage: AskNewConversationBar.Storage
    @State private var presented = false

    private var tint: Color? {
        switch storage {
        case .temporary: AskTheme.temporaryTint
        case .choice(.local): AskLocalModeCard.tint(.local)
        default: nil
        }
    }

    var body: some View {
        AskBarButton(symbol: storage.kind.symbol, title: L(storage.kind.titleKey),
                     tint: tint, chevron: true, help: L("ask.storage.card.title")) { presented.toggle() }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .modifier(AskWorkspaceShortcutBadge(shortcut: "⌘⇧L"))
            .accessibilityIdentifier("ask.newConversation.storage")
            .askMenu(isPresented: $presented, glass: true) {
                AskObservedContent(model: model) {
                    AskStorageChoiceMenu(selection: model.storageKind(launcher: false), signedIn: model.isSignedIn) { choice in
                        presented = false
                        model.chooseStorage(choice, launcher: false)
                    }
                }
            }
    }
}

/// Storage choices, including temporary chats. Cloud requires a signed-in account.
struct AskStorageChoiceMenu: View {
    let selection: AskStorageKind
    let signedIn: Bool
    var choose: (AskStorageKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWorkFolderList.header(L("ask.bar.storage.header"))
            ForEach(signedIn ? [AskStorageKind.cloud, .local, .temporary] : [.local, .temporary], id: \.self) { kind in
                AskAddMenuRow(symbol: kind.symbol, title: L(kind.titleKey), detail: L(kind.detailKey),
                              active: kind == selection, action: { choose(kind) }) {
                    if kind == selection {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AskTheme.accent)
                    }
                }
                .accessibilityAddTraits(kind == selection ? .isSelected : [])
                .accessibilityIdentifier("ask.newConversation.storage." + String(describing: kind))
            }
            if signedIn {
                Text(L("ask.bar.storage.footer"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}
