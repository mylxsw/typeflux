import AppKit
import SwiftUI

/// What the side panel needs from the conversation it sits beside.
struct AskSidePanelContext {
    /// The selected conversation; nil on a new chat, which has no files yet.
    var conversationId: String?
    /// The selected conversation while its run is active; only its browser activity shows controls.
    var runningConversationId: String?
    /// The conversation's message ids, oldest first, to order the file groups.
    var messageOrder: [String] = []
    /// A short title for the message a file group belongs to.
    var messageTitle: (String) -> String? = { _ in nil }
    /// Folders a file tab may read: the workspace and the conversation's granted folders.
    var roots: () -> [String] = { [] }
    var refreshFiles: () -> Void = {}
    var addFiles: ([URL]) -> Void = { _ in }
    var stopRun: () -> Void = {}
}

/// The panel beside the conversation: one tab strip for the pinned Files tab, web pages and
/// files, and the selected tab's content.
struct AskSidePanelView: View {
    @ObservedObject var panel: AskSidePanel
    var context: AskSidePanelContext
    /// Clears the traffic lights when a narrow window shows the panel alone.
    var leadingInset: CGFloat = 0
    var close: () -> Void
    /// Drag of the leading edge since the drag began, in points (positive widens);
    /// nil when the drag ends.
    var resize: ((CGFloat?) -> Void)?
    @State private var dragStart: CGFloat?
    @State private var addressFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
                .padding(.leading, leadingInset)
                .frame(height: AskMetrics.titleBarRowHeight - 1)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            if let notice = panel.notice { noticeBanner(notice) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { shortcuts }
        .overlay(alignment: .leading) { resizeHandle }
        .askSidePanel(edge: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.sidePanel")
    }

    @ViewBuilder private var content: some View {
        switch panel.selectedTab ?? .files {
        case .files:
            AskFilesTabView(panel: panel, context: context, open: open)
        case .web:
            if let browser = panel.browser {
                AskBrowserPanel(workspace: browser, runningConversationId: context.runningConversationId,
                                stopRun: context.stopRun, focusRequest: addressFocusRequest)
            }
        case let .file(tab):
            AskFileTabView(tab: tab, roots: context.roots) { panel.notice = $0 }
                .id(tab.id)
        }
    }

    private func open(_ file: AskWorkspaceFile) {
        guard let conversationId = context.conversationId, let root = panel.filesRoot else { return }
        do {
            let target = try AskSidePanelFileAccess.resolve(file.relativePath, workspaceRoot: root)
            try panel.open(target, conversationId: conversationId)
            panel.notice = nil
        } catch {
            panel.notice = error.localizedDescription
        }
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        HStack(spacing: 4) {
            AskSidePanelTabButton(symbol: "folder", title: L("ask.sidePanel.files"),
                                  selected: panel.selection == .files || panel.selectedTab == nil,
                                  select: { panel.showFiles() }, close: nil)
                .padding(.leading, 10)
                .accessibilityIdentifier("ask.sidePanel.files")
            Rectangle().fill(AskTheme.separator).frame(width: 1, height: 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(panel.tabs.dropFirst(), id: \.id) { item in
                        tabButton(item)
                    }
                }
            }
            if panel.browser != nil {
                Menu {
                    Button(L("ask.web.newTab")) { newWebTab(isPrivate: false) }
                    Button(L("ask.web.newPrivateTab")) { newWebTab(isPrivate: true) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13)).frame(width: 26, height: 26)
                } primaryAction: {
                    newWebTab(isPrivate: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("ask.web.newTab"))
                .accessibilityIdentifier("ask.web.newTab")
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .help(L("ask.sidePanel.close"))
            .accessibilityLabel(L("ask.sidePanel.close"))
            .accessibilityIdentifier("ask.workspace.drawer.close")
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder private func tabButton(_ item: AskSidePanelTab) -> some View {
        switch item {
        case .files:
            EmptyView()
        case let .web(tab):
            if let browser = panel.browser {
                AskSidePanelWebTabButton(tab: tab, browser: browser, selected: panel.selection == item.id,
                                         runningConversationId: context.runningConversationId,
                                         select: { panel.select(item.id) }, close: { panel.close(item.id) })
            }
        case let .file(tab):
            AskSidePanelTabButton(symbol: AskFileIcon.symbol(for: tab.kind), title: tab.name,
                                  selected: panel.selection == item.id,
                                  select: { panel.select(item.id) }, close: { panel.close(item.id) })
                .help(tab.target.relativePath)
        }
    }

    private func newWebTab(isPrivate: Bool) {
        do {
            try panel.newWebTab(isPrivate: isPrivate)
            addressFocusRequest += 1
        } catch {
            panel.notice = error.localizedDescription
        }
    }

    /// ⌘W closes the selected tab; the Files tab stays.
    private var shortcuts: some View {
        Button("") { panel.closeSelected() }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!panel.canCloseSelection)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(StudioTheme.warning)
            Text(notice).font(.system(size: 12)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("ask.web.dismiss")) { panel.notice = nil }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(StudioTheme.warning.opacity(0.08))
        .accessibilityIdentifier("ask.sidePanel.notice")
    }

    @ViewBuilder private var resizeHandle: some View {
        if let resize {
            Color.clear
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? value.startLocation.x
                        dragStart = start
                        resize(start - value.location.x)
                    }
                    .onEnded { _ in dragStart = nil; resize(nil) })
                .accessibilityHidden(true)
        }
    }
}

/// One tab in the strip. The Files tab passes no `close`: it cannot be closed.
struct AskSidePanelTabButton: View {
    var symbol: String
    var title: String
    var selected: Bool
    var agent = false
    var select: () -> Void
    var close: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? StudioTheme.textSecondary : StudioTheme.textTertiary)
                if agent { Circle().fill(AskTheme.accent).frame(width: 6, height: 6).offset(x: -3, y: -3) }
            }
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .frame(maxWidth: 140, alignment: .leading)
                .fixedSize(horizontal: close == nil, vertical: false)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityLabel(L("ask.web.closeTab"))
            }
        }
        .padding(.leading, 10).padding(.trailing, close == nil ? 10 : 5)
        .frame(height: 28)
        .background(selected ? AskTheme.controlSurface : (hovering ? AskTheme.hoverFill : .clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select() }
    }
}

/// A web tab follows its page's title, and marks the page the running AI acts on.
private struct AskSidePanelWebTabButton: View {
    @ObservedObject var tab: AskBrowserTab
    @ObservedObject var browser: AskBrowserWorkspace
    var selected: Bool
    var runningConversationId: String?
    var select: () -> Void
    var close: () -> Void

    var body: some View {
        let agent = runningConversationId != nil && browser.activity?.conversationId == runningConversationId
            && browser.activity?.tabId == tab.id
        AskSidePanelTabButton(symbol: tab.isPrivate ? "eyeglasses" : "globe", title: tab.displayTitle,
                              selected: selected, agent: agent, select: select, close: close)
    }
}

enum AskFileIcon {
    static func symbol(for kind: AskSidePanelFileKind) -> String {
        switch kind {
        case .html: "globe"
        case .markdown: "doc.richtext"
        case .csv: "tablecells"
        case .image: "photo"
        case .pdf: "doc.text.image"
        case .text: "chevron.left.forwardslash.chevron.right"
        case .unsupported: "doc"
        }
    }

    static func symbol(forExtension ext: String) -> String {
        symbol(for: AskSidePanelFileKind.kind(forExtension: ext))
    }
}
