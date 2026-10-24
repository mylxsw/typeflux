import AppKit
import SwiftUI
import WebKit

/// A web tab of the side panel: address bar, the page, and the controls the user has
/// while the AI works in it. `AskSidePanelView` draws the tab strip around it.
struct AskBrowserPanel: View {
    @ObservedObject var workspace: AskBrowserWorkspace
    /// The selected conversation while its run is active; only its activity shows controls.
    var runningConversationId: String?
    var stopRun: () -> Void
    /// Bumped when the user opens a new tab, to type its address.
    var focusRequest = 0
    /// The side panel's shortcuts on a new tab: the conversation's files and recent items.
    var start = AskBrowserStartShortcuts()
    @State private var address = ""
    @State private var editingAddress = false
    @State private var showsSites = false
    @FocusState private var addressFocused: Bool

    private var tab: AskBrowserTab? { workspace.selectedTab }
    private var agentConversation: Bool {
        runningConversationId != nil && workspace.activity?.conversationId == runningConversationId
    }
    private var agentOnTab: Bool { agentConversation && workspace.activity?.tabId == tab?.id }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ZStack {
                if let tab {
                    AskBrowserWebView(tab: tab)
                        .id(tab.id)
                    if tab.url == nil { AskBrowserStartPage(workspace: workspace, tab: tab, shortcuts: start) }
                } else {
                    AskBrowserStartPage(workspace: workspace, tab: nil, shortcuts: start)
                }
                overlays
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(agentOnTab ? AskTheme.accent : AskTheme.separator,
                                  lineWidth: agentOnTab && !workspace.paused && workspace.handoff == nil ? 2 : 1)
            }
            .padding([.horizontal, .bottom], 8)
        }
        .sheet(isPresented: $showsSites) { AskBrowserSitesView(workspace: workspace) }
        .onAppear(perform: syncAddress)
        .onChange(of: tab?.url) { _ in syncAddress() }
        .onChange(of: workspace.selectedTabId) { _ in syncAddress() }
        .onChange(of: focusRequest) { _ in
            address = ""
            addressFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.web.panel")
    }

    private func syncAddress() {
        guard !editingAddress else { return }
        address = tab?.url?.absoluteString ?? ""
    }

    // MARK: - Address bar

    private var navigationBar: some View {
        HStack(spacing: 2) {
            iconButton("chevron.left", label: L("ask.web.back"), enabled: tab?.canGoBack == true) {
                tab?.webView.goBack()
            }
            iconButton("chevron.right", label: L("ask.web.forward"), enabled: tab?.canGoForward == true) {
                tab?.webView.goForward()
            }
            iconButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", label: L("ask.web.reload"),
                       enabled: tab?.url != nil) {
                if tab?.isLoading == true { tab?.webView.stopLoading() } else { tab?.webView.reload() }
            }
            HStack(spacing: 6) {
                Image(systemName: tab?.isPrivate == true ? "eyeglasses" : (tab?.url?.scheme == "https" ? "lock" : "globe"))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.web.addressPlaceholder"), text: $address, onEditingChanged: { editingAddress = $0 })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($addressFocused)
                    .onSubmit(submitAddress)
                    .accessibilityIdentifier("ask.web.address")
                if let host = AskHTTPOrigin(tab?.url)?.description, workspace.policy.permission(for: host) != .off,
                   tab?.isPrivate == false {
                    Text(workspace.policy.permission(for: host).title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AskTheme.accentText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(AskTheme.accentSoft, in: Capsule())
                        .help(L("ask.web.permission.help"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(AskTheme.controlSurface, in: Capsule())
            .overlay(alignment: .bottom) {
                if let tab, tab.isLoading {
                    GeometryReader { geometry in
                        Capsule().fill(AskTheme.accent)
                            .frame(width: geometry.size.width * tab.progress, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                }
            }
            Menu {
                Button(L("ask.web.openExternally")) { if let url = tab?.url { NSWorkspace.shared.open(url) } }
                    .disabled(tab?.url == nil)
                Button(L("ask.web.copyLink")) {
                    guard let url = tab?.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .disabled(tab?.url == nil)
                Divider()
                Button(L("ask.web.sites.title")) { showsSites = true }
                if let host = tab?.host {
                    Button(L("ask.web.clearSite", host), role: .destructive) {
                        Task { await workspace.clearData(for: host); tab?.webView.reload() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(StudioTheme.textSecondary)
            .fixedSize()
            .accessibilityLabel(L("ask.web.more"))
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func submitAddress() {
        guard let url = AskBrowserWorkspace.url(forInput: address) else { return }
        if let tab { tab.load(url) } else { _ = try? workspace.newTab(url: url) }
        addressFocused = false
    }
}

extension AskBrowserPanel {
    // MARK: - Overlays

    @ViewBuilder private var overlays: some View {
        VStack(spacing: 0) {
            if let handoff = workspace.handoff, handoff.tabId == tab?.id {
                banner(symbol: "key", tint: StudioTheme.warning,
                       title: L("ask.web.handoff." + handoff.reason.rawValue),
                       detail: handoff.message.isEmpty ? L("ask.web.handoff.private") : handoff.message
                           + " · " + L("ask.web.handoff.private")) {
                    Button(L("ask.web.handoff.cancel")) { workspace.finishHandoff(completed: false) }
                        .buttonStyle(.borderless)
                    Button(L("ask.web.handoff.done")) { workspace.finishHandoff(completed: true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ask.web.handoff.done")
                }
            } else if agentOnTab, workspace.takenOver {
                banner(symbol: "hand.raised", tint: AskTheme.accent, title: L("ask.web.takenOver"),
                       detail: L("ask.web.takenOver.detail")) {
                    Button(L("ask.web.giveBack")) { workspace.setPaused(false) }
                        .buttonStyle(.borderedProminent)
                }
            } else if let notice = tab?.notice {
                banner(symbol: "exclamationmark.triangle", tint: StudioTheme.warning, title: notice, detail: nil) {
                    Button(L("ask.web.dismiss")) { tab?.notice = nil }.buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
            if agentOnTab, workspace.handoff == nil { controlBar }
        }
        .padding(10)
        .animation(.easeOut(duration: 0.18), value: agentOnTab)
    }

    private func banner(symbol: String, tint: Color, title: String, detail: String?,
                        @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AskTheme.popoverSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.45)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Circle().fill(workspace.paused ? StudioTheme.warning : AskTheme.accent).frame(width: 7, height: 7)
            Text(workspace.paused ? L("ask.web.paused") : (workspace.activity?.text ?? ""))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            Button(workspace.paused ? L("ask.web.resume") : L("ask.web.pause")) {
                workspace.setPaused(!workspace.paused)
            }
            .accessibilityIdentifier("ask.web.pause")
            if !workspace.takenOver {
                Button(L("ask.web.takeOver")) { workspace.setPaused(true, takenOver: true) }
                    .accessibilityIdentifier("ask.web.takeOver")
            }
            Button(L("ask.web.stop"), role: .destructive, action: stopRun)
                .accessibilityIdentifier("ask.web.stop")
        }
        .controlSize(.small)
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(AskTheme.separator))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    // MARK: - Controls

    private func iconButton(_ symbol: String, label: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5))
                .foregroundStyle(enabled ? StudioTheme.textSecondary : StudioTheme.textTertiary.opacity(0.6))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Hosts the tab's own web view; the view outlives this representable.
struct AskBrowserWebView: NSViewRepresentable {
    @ObservedObject var tab: AskBrowserTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if tab.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        tab.webView.removeFromSuperview()
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tab.webView)
        NSLayoutConstraint.activate([
            tab.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tab.webView.topAnchor.constraint(equalTo: container.topAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
