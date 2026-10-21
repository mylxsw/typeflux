import SwiftUI

/// A blank tab showing the sites the user is signed in to.
struct AskBrowserStartPage: View {
    @ObservedObject var workspace: AskBrowserWorkspace
    var tab: AskBrowserTab?
    @State private var sites: [AskBrowserWorkspace.Site] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if tab?.isPrivate == true {
                    note("eyeglasses", L("ask.web.private.detail"))
                }
                if !sites.isEmpty {
                    Text(L("ask.web.signedIn")).font(.system(size: 12.5, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(sites.filter(\.hasData)) { site in
                            Button { open("https://" + site.host) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "globe").foregroundStyle(StudioTheme.textTertiary)
                                    Text(site.host).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10).frame(height: 34)
                                .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AskTheme.surface)
        .task { sites = await workspace.sites() }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func open(_ text: String) {
        guard let url = URL(string: text) else { return }
        if let tab { tab.load(url) } else { _ = try? workspace.newTab(url: url) }
    }
}

/// Sites & sign-ins: what the AI may do on each site, and signing out.
struct AskBrowserSitesView: View {
    @ObservedObject var workspace: AskBrowserWorkspace
    @ObservedObject private var policy: AskBrowserSitePolicy
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [AskBrowserWorkspace.Site] = []
    @State private var confirmsClearAll = false

    init(workspace: AskBrowserWorkspace) {
        self.workspace = workspace
        policy = workspace.policy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("ask.web.sites.title")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 18)
            Text(L("ask.web.sites.detail"))
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if sites.isEmpty {
                Text(L("ask.web.sites.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sites) { site in
                            row(site)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 360)
            }
            HStack {
                Image(systemName: "lock.shield")
                Text(L("ask.web.sites.privacy")).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("ask.web.sites.clearAll"), role: .destructive) { confirmsClearAll = true }
                    .disabled(!sites.contains(where: \.hasData))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(18)
        }
        .frame(width: 560)
        .task { await reload() }
        .confirmationDialog(L("ask.web.sites.clearAll.confirm"), isPresented: $confirmsClearAll) {
            Button(L("ask.web.sites.clearAll"), role: .destructive) {
                Task { await workspace.clearAllData(); await reload() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    private func row(_ site: AskBrowserWorkspace.Site) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(StudioTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.host).font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(site.host)
                Text(L(site.isOrigin ? "ask.web.sites.exactOrigin" : site
                        .isLegacy ? "ask.web.sites.legacy" : "ask.web.sites.signedIn"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(3)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if site.isLegacy { Text(site.permission.title).font(.caption) }
            Spacer(minLength: 8)
            if site.isOrigin {
                Picker("", selection: Binding(get: { policy.permission(for: site.host) },
                                              set: { policy.set($0, for: site.host) })) {
                    ForEach(AskBrowserSitePermission.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel(L("ask.web.permission.label", site.host))
            }
            Button {
                Task {
                    if site.isOrigin || site.isLegacy {
                        policy.remove(site.host)
                    } else {
                        await workspace.clearData(for: site.host)
                    }
                    await reload()
                }
            } label: {
                Image(systemName: "trash").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!site.hasData && !site.isOrigin && !site.isLegacy)
            .help(L(site.isOrigin || site.isLegacy ? "ask.web.removePermission" : "ask.web.clearSite", site.host))
            .accessibilityLabel(L(site.isOrigin || site.isLegacy ? "ask.web.removePermission" : "ask.web.clearSite", site.host))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func reload() async { sites = await workspace.sites() }
}
