import SwiftUI

/// "Chat | Work" for a conversation that has not started: centred at the top of the
/// new-conversation page with labels, and icon-only at the start of the launcher's bar,
/// which keeps its empty space for dragging the panel.
struct AskConversationKindSwitch: View {
    let selection: AskConversationKind
    var compact = false
    var onSelect: (AskConversationKind) -> Void
    @Environment(\.interfaceStyle) private var style

    private var height: CGFloat { compact ? 26 : AskMetrics.headerCapsuleHeight }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AskConversationKind.allCases, id: \.self) { kind in
                let chosen = selection == kind
                Button { onSelect(kind) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol).font(.system(size: compact ? 11 : 12, weight: .medium))
                        if !compact {
                            Text(L(kind.titleKey))
                                .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(chosen ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .padding(.horizontal, compact ? 7 : 16)
                    .frame(height: height - 6)
                    .background {
                        if chosen {
                            Capsule(style: .continuous)
                                .fill(style.usesGlass ? AskTheme.controlSurface : AskClassic.card)
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L(kind.titleKey) + " · " + L(kind.titleKey + ".help"))
                .accessibilityLabel(L(kind.titleKey))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("ask.kind." + kind.rawValue)
            }
        }
        .padding(3)
        .frame(height: height)
        .background {
            if compact { Capsule(style: .continuous).fill(AskTheme.hoverFill) }
        }
        .modifier(AskKindSwitchSurface(enabled: !compact, height: height))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.kind.switch"))
    }
}

/// The full-size switch floats on the same glass capsule as the header's title.
private struct AskKindSwitchSurface: ViewModifier {
    let enabled: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        if enabled { content.askInWindowGlassPill(height: height) } else { content }
    }
}

/// Replaces the composer for a conversation another device runs: this Mac reads its
/// synchronized history but cannot continue it, and can start a new chat instead.
struct AskHostElsewhereNotice: View {
    let host: String
    let kind: AskConversationKind
    var onNewChat: () -> Void
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(StudioTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(kind == .work ? "ask.host.workTitle" : "ask.host.chatTitle", host))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L("ask.host.detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L("ask.host.newChat"), action: onNewChat)
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                .accessibilityIdentifier("ask.host.newChat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(style.usesGlass ? AskTheme.controlSurface : AskClassic.card,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AskTheme.separator, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.host.notice")
    }
}

/// A task's environment in one control: the tool permission's icon and name, then the folders it
/// works in. The menu adds folders, at the start or during the task, and picks the mode.
/// The launcher keeps its bar's empty space for dragging, so it shows the shield alone.
struct AskWorkEnvironmentButton: View {
    @ObservedObject var model: AskConversationModel
    var launcher = false
    /// Hide folder details while keeping the permission name outside the launcher.
    var compact = false
    @State private var presented = false
    @State private var hovering = false

    /// The folders a task's next message works in: the default workspace, one name, or the first and a count.
    static func title(_ draft: AskDraft) -> String {
        let folders = (draft.attachments ?? []).filter { $0.kind == .folder }
        guard let first = folders.first else { return L("ask.kind.defaultWorkspace") }
        return folders.count == 1 ? first.name : L("ask.kind.folders", first.name, folders.count - 1)
    }

    /// Folders the next message adds to the task.
    static func hasPendingFolders(_ draft: AskDraft) -> Bool {
        draft.attachments?.contains { $0.kind == .folder } == true
    }

    private var mode: AskPermissionMode { model.permissionMode(launcher: launcher) }
    private var draft: AskDraft { launcher ? model.launcherDraft : model.draft }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: AskMetrics.footerStatusSymbolSize, weight: .semibold))
                    .foregroundStyle(AskPermissionModeMenu.tint(mode))
                if !launcher {
                    Text(verbatim: mode == .yolo ? "YOLO" : mode.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AskPermissionModeMenu.tint(mode))
                }
                if !compact {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                        .padding(.leading, 2)
                    Text(Self.title(draft)).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !launcher {
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(hovering || presented ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: AskMetrics.composerControlHeight)
            .background(hovering || presented ? AskTheme.hoverFill : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Like the permission menu it replaces, it keeps its size; the folder name truncates first.
        .fixedSize()
        .onHover { hovering = $0 }
        .help(L("ask.env.help"))
        .accessibilityLabel(L("ask.mode.title") + ": " + mode.title)
        .accessibilityValue(Self.title(draft))
        .accessibilityIdentifier("ask.composer.permissionMode")
        .askMenu(isPresented: $presented, glass: true) {
            AskObservedContent(model: model) { menu }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskWorkFolderList(model: model, launcher: launcher) { presented = false }
            Rectangle().fill(AskTheme.separator).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 6)
            AskWorkFolderList.header(L("ask.mode.title"))
            ForEach(AskPermissionMode.allCases, id: \.self) { option in
                AskPopoverRow(title: option.title, caption: option.detail, selected: option == mode, action: {
                    presented = false
                    model.setPermissionMode(option, launcher: launcher)
                }, accessory: {
                    Image(systemName: option.symbol).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(option == mode
                            ? AskPermissionModeMenu.tint(option) : StudioTheme.textSecondary)
                })
                .accessibilityIdentifier("ask.env.mode." + option.rawValue)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 320, alignment: .leading)
    }
}

/// The folders a task works in: the default workspace or the ones added for the next
/// message, each removable, then "Add folder" and the grants this session holds.
/// The task's environment menu and the new conversation's folder button share it.
struct AskWorkFolderList: View {
    @ObservedObject var model: AskConversationModel
    var launcher = false
    /// Closes the surrounding menu before the open panel appears.
    var dismiss: () -> Void = {}

    private var draft: AskDraft { launcher ? model.launcherDraft : model.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Self.header(L("ask.env.folders"))
            // A started task already works in its folders (listed below when granted);
            // name only what the next message adds, or the default for a new task.
            let folders = (draft.attachments ?? []).filter { $0.kind == .folder }
            if folders.isEmpty, model.canChangeConversationKind(launcher: launcher) {
                folderRow(L("ask.kind.defaultWorkspace"))
            }
            ForEach(folders) { folder in
                HStack(spacing: 4) {
                    folderRow(folder.name)
                    Button { model.removeAttachment(folder.id, launcher: launcher) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .frame(width: 26, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .accessibilityLabel(L("ask.remove") + ": " + folder.name)
                    .accessibilityIdentifier("ask.env.removeFolder." + folder.id)
                }
                .help(folder.path ?? folder.name)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ask.env.folder." + folder.id)
            }
            AskPopoverRow(title: L("ask.env.addFolder"), caption: nil, selected: false,
                          action: {
                              dismiss()
                              model.pickAttachments(folders: true, launcher: launcher)
                          }, accessory: {
                              Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                          })
                .accessibilityIdentifier("ask.env.addFolder")
            AskFolderPermissionControls(model: model, launcher: launcher)
                .padding(.horizontal, 10)
        }
    }

    static func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)
    }

    private func folderRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary).frame(width: 14)
            Text(title).font(.system(size: 13)).foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14).frame(height: 30)
    }
}

/// Typeflux Cloud cannot be reached and the composer is on a Cloud model: say so and
/// offer a local model. Nothing is queued to send later.
struct AskOfflineNotice: View {
    let suggestion: AskOfflineSuggestion
    let library: AskModelLibrary
    var onApply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(StudioTheme.warning)
            Text(message).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: onApply)
                    .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                    .accessibilityIdentifier("ask.offline.apply")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AskTheme.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.offline.notice")
    }

    private var message: String {
        switch suggestion {
        case .useLocalModel: L("ask.offline.newConversation")
        case .continueLocally: L("ask.offline.started")
        case .needsLocalModel: L("ask.offline.noLocalModel")
        }
    }

    private var action: String? {
        switch suggestion {
        case let .useLocalModel(reference): L("ask.offline.useModel", library.name(for: reference))
        case let .continueLocally(reference): L("ask.offline.continueWith", library.name(for: reference))
        case .needsLocalModel: nil
        }
    }
}
