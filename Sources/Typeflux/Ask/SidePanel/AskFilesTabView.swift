import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pinned Files tab: the conversation's uploads, generated files and work files,
/// filtered by origin, searched by name and grouped by the message they came with.
struct AskFilesTabView: View {
    @ObservedObject var panel: AskSidePanel
    var context: AskSidePanelContext
    var open: (AskWorkspaceFile) -> Void
    @AppStorage("ask.sidePanel.filesGrid") private var showsGrid = false

    private var groups: [AskWorkspaceFileQuery.Group] {
        panel.fileQuery.groups(panel.files, messageOrder: context.messageOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            listing
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.sidePanel.filesTab")
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                    TextField(L("ask.sidePanel.files.search"), text: $panel.fileQuery.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .accessibilityIdentifier("ask.sidePanel.files.search")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(AskTheme.controlSurface, in: Capsule())
                layoutButton("list.bullet", grid: false)
                layoutButton("square.grid.2x2", grid: true)
                Button(action: context.refreshFiles) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(context.conversationId == nil || panel.filesLoading)
                .help(L("ask.sidePanel.files.refresh"))
                .accessibilityLabel(L("ask.sidePanel.files.refresh"))
            }
            originFilter
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var originFilter: some View {
        let counts = AskWorkspaceFileQuery.counts(panel.files)
        return HStack(spacing: 4) {
            filterChip(nil, title: L("ask.sidePanel.files.all"), count: panel.files.count)
            ForEach(AskWorkspaceFile.Origin.allCases, id: \.self) { origin in
                filterChip(origin, title: Self.title(origin), count: counts[origin] ?? 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(_ origin: AskWorkspaceFile.Origin?, title: String, count: Int) -> some View {
        let selected = panel.fileQuery.origin == origin
        return Button {
            panel.fileQuery.origin = origin
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").foregroundStyle(StudioTheme.textTertiary).monospacedDigit()
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? AskTheme.accentText : StudioTheme.textSecondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(selected ? AskTheme.accentSoft : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func layoutButton(_ symbol: String, grid: Bool) -> some View {
        Button { showsGrid = grid } label: {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(showsGrid == grid ? AskTheme.accent : StudioTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(grid ? "ask.sidePanel.files.grid" : "ask.sidePanel.files.list"))
        .accessibilityLabel(L(grid ? "ask.sidePanel.files.grid" : "ask.sidePanel.files.list"))
        .accessibilityAddTraits(showsGrid == grid ? .isSelected : [])
    }

    static func title(_ origin: AskWorkspaceFile.Origin) -> String {
        switch origin {
        case .upload: L("ask.sidePanel.files.uploads")
        case .generated: L("ask.sidePanel.files.generated")
        case .process: L("ask.sidePanel.files.work")
        }
    }

    // MARK: - Listing

    @ViewBuilder private var listing: some View {
        if context.conversationId == nil {
            placeholder("bubble.left.and.text.bubble.right", L("ask.sidePanel.files.noConversation"))
        } else if let error = panel.filesError {
            placeholder("exclamationmark.triangle", error)
        } else if panel.files.isEmpty {
            if panel.filesLoading {
                ProgressView().controlSize(.small)
            } else {
                placeholder("tray", L("ask.sidePanel.files.empty"))
            }
        } else if groups.isEmpty {
            placeholder("magnifyingglass", L("ask.sidePanel.files.noMatch"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            groupHeader(group)
                            if showsGrid {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                                    ForEach(group.files) { file in
                                        AskWorkspaceFileTile(file: file, url: url(file), open: { open(file) },
                                                             onError: { panel.notice = $0 })
                                    }
                                }
                            } else {
                                ForEach(group.files) { file in
                                    AskWorkspaceFileRow(file: file, url: url(file), open: { open(file) },
                                                        onError: { panel.notice = $0 })
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func url(_ file: AskWorkspaceFile) -> URL? {
        panel.filesRoot?.appendingPathComponent(file.relativePath)
    }

    private func groupHeader(_ group: AskWorkspaceFileQuery.Group) -> some View {
        let title = group.messageId.flatMap(context.messageTitle) ?? L(group.messageId == nil
            ? "ask.sidePanel.files.unassigned" : "ask.sidePanel.files.earlierMessage")
        return HStack(spacing: 6) {
            Image(systemName: group.messageId == nil ? "tray" : "text.bubble")
                .font(.system(size: 10.5))
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(group.files.count)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light))
            Text(text).font(.system(size: 12.5)).multilineTextAlignment(.center)
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if let root = panel.filesRoot { NSWorkspace.shared.open(root) }
            } label: {
                Label(L("ask.sidePanel.revealInFinder"), systemImage: "folder")
            }
            .disabled(panel.filesRoot == nil)
            .accessibilityIdentifier("ask.sidePanel.files.reveal")
            Spacer(minLength: 0)
            Button {
                let picker = NSOpenPanel()
                picker.allowsMultipleSelection = true
                picker.canChooseDirectories = false
                picker.canChooseFiles = true
                guard picker.runModal() == .OK, !picker.urls.isEmpty else { return }
                context.addFiles(picker.urls)
            } label: {
                Label(L("ask.sidePanel.files.add"), systemImage: "plus")
            }
            .disabled(context.conversationId == nil)
            .accessibilityIdentifier("ask.sidePanel.files.add")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

/// Size, time and origin under a file's name.
enum AskWorkspaceFileFormat {
    static func detail(_ file: AskWorkspaceFile, now: Date = Date()) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.unitsStyle = .abbreviated
        let time = file.modifiedAt == .distantPast ? "" : " · " + formatter.localizedString(for: file.modifiedAt,
                                                                                          relativeTo: now)
        return size + time + " · " + AskFilesTabView.title(file.origin)
    }
}

/// A file in the list: click opens it in a tab; hover shows the open menu.
private struct AskWorkspaceFileRow: View {
    let file: AskWorkspaceFile
    let url: URL?
    var open: () -> Void
    var onError: (String) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AskWorkspaceFileIconView(file: file, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(AskWorkspaceFileFormat.detail(file)).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url {
                Menu {
                    AskFileOpenMenuItems(file: url, showsShortcuts: false, onError: onError)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel(L("ask.sidePanel.open.menu"))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(hovering ? AskTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("ask.sidePanel.open.inPanel"), action: open)
            if let url { AskFileOpenMenuItems(file: url, onError: onError) }
        }
        .help(file.relativePath)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("ask.sidePanel.open.inPanel"), open)
    }
}

/// A file in the grid.
private struct AskWorkspaceFileTile: View {
    let file: AskWorkspaceFile
    let url: URL?
    var open: () -> Void
    var onError: (String) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            AskWorkspaceFileIconView(file: file, size: 44)
                .frame(height: 52)
            Text(file.name).font(.system(size: 11.5)).lineLimit(2).multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(StudioTheme.textPrimary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .top)
        .background(hovering ? AskTheme.hoverFill : AskTheme.controlSurface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("ask.sidePanel.open.inPanel"), action: open)
            if let url { AskFileOpenMenuItems(file: url, onError: onError) }
        }
        .help(file.relativePath + "\n" + AskWorkspaceFileFormat.detail(file))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("ask.sidePanel.open.inPanel"), open)
    }
}

/// The Finder icon for the file's type; never reads the file itself.
private struct AskWorkspaceFileIconView: View {
    let file: AskWorkspaceFile
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: file.pathExtension) ?? .data))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
