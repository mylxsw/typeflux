import AppKit
import SwiftUI

/// Settings › Launcher › Search: how the launcher finds applications and files,
/// where it looks, what it leaves out, and how the file index is doing.
struct LauncherSearchSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, apps, files, browsers, exclude

        var id: String {
            rawValue
        }

        var title: String {
            L("launcher.search.tab.\(rawValue)")
        }
    }

    let settings: SettingsStore
    var index: any AskFileSearching = AskFileIndex.shared
    var fullDiskAccess: () -> Bool = { AskFullDiskAccess.isGranted() }

    @State var tab: Tab = .general
    @State var search = AskLauncherSearchSettings()
    @State var appsEnabled = true
    @State var filesEnabled = true
    @State var previewEnabled = true
    @State var browserPreferences = AskBrowserSearchSettings()
    @State var status = AskFileIndexStatus()
    @State var hasFullDiskAccess = false
    @State private var permissionTask: Task<Void, Never>?
    @State var newExtension = ""
    @State var newFolderName = ""

    var body: some View {
        TypefluxForm {
            Section {
                TypefluxSettingsRow(LauncherSettingsPane.search.title) {
                    TypefluxPopup(LauncherSettingsPane.search.title, selection: $tab, borderless: true) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("launcher.search.tabs")
                }
            }
            switch tab {
            case .general: generalTab
            case .apps: appsTab
            case .files: filesTab
            case .browsers: browsersTab
            case .exclude: excludeTab
            }
        }
        .onAppear(perform: reload)
        .onDisappear { permissionTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: AskFileIndex.didChange)) { _ in status = index.status }
    }

    // MARK: - General

    @ViewBuilder private var generalTab: some View {
        AgentSettingsSection(title: L("launcher.search.general")) {
            AgentSettingsRow(icon: "doc.viewfinder", title: L("launcher.search.preview"),
                             subtitle: L("launcher.search.preview.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: Binding(get: { previewEnabled }, set: {
                    previewEnabled = $0; settings.askFilePreviewEnabled = $0
                })).labelsHidden().toggleStyle(.switch).accessibilityLabel(L("launcher.search.preview"))
            }
            AgentSettingsRow(icon: "wand.and.stars", title: L("launcher.search.fuzzy"),
                             subtitle: L("launcher.search.fuzzy.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: binding(\.fuzzy)).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("launcher.search.fuzzy"))
            }
            AgentSettingsRow(icon: "list.number", title: L("launcher.search.limit"),
                             subtitle: L("launcher.search.limit.subtitle"), subtitleLineLimit: nil) {
                TypefluxPopup(title: L("launcher.search.limit"),
                              options: AskLauncherSearchSettings.limits.map { (label: "\($0)", value: $0) },
                              selection: binding(\.limit))
                    .frame(width: 90)
            }
            AgentSettingsRow(icon: "photo", title: L("launcher.search.icons"),
                             subtitle: L("launcher.search.icons.subtitle"), subtitleLineLimit: nil) {
                TypefluxSegmentedControl(L("launcher.search.icons"), selection: binding(\.fileIcons)) {
                    ForEach(AskLauncherSearchSettings.FileIcons.allCases, id: \.self) {
                        Text(L("launcher.search.icons.\($0.rawValue)")).tag($0)
                    }
                }
                .accessibilityLabel(L("launcher.search.icons"))
            }
        }
        AgentSettingsSection(title: L("launcher.search.permission")) {
            AgentSettingsRow(icon: "lock.shield", title: L("launcher.search.fda"),
                             subtitle: L("launcher.search.fda.subtitle"), subtitleLineLimit: nil) {
                HStack(spacing: 10) {
                    TypefluxStatus(L(hasFullDiskAccess ? "launcher.search.fda.granted" : "launcher.search.fda.missing"),
                                   tone: hasFullDiskAccess ? .success : .warning)
                    if !hasFullDiskAccess {
                        Button(L("launcher.search.fda.open")) { NSWorkspace.shared.open(AskFullDiskAccess.settingsURL) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Applications

    @ViewBuilder private var appsTab: some View {
        Section {
            AgentSettingsRow(icon: "square.grid.2x2", title: L("ask.settings.quick.apps.title")) {
                Toggle("", isOn: Binding(get: { appsEnabled }, set: setAppsEnabled))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("ask.settings.quick.apps.title"))
                    .accessibilityIdentifier("launcher.search.apps.enabled")
            }
        }
        AgentSettingsSection(title: L("launcher.search.apps.roots"), detail: "\(search.appRoots.count)",
                             footnote: L("launcher.search.apps.footnote")) {
            ForEach(search.appRoots, id: \.self) { root in
                pathRow(root, icon: root.hasSuffix(".app") ? "app" : "folder") {
                    update { $0.appRoots.removeAll { $0 == root } }
                }
            }
            AgentSettingsActionRow(icon: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: true) {
                    update { $0.appRoots = Self.adding(paths, to: $0.appRoots) }
                }
            }
            AgentSettingsActionRow(icon: "arrow.counterclockwise", title: L("launcher.search.reset")) {
                update { $0.appRoots = AskLauncherSearchSettings.defaultAppRoots }
            }
        }
        AgentSettingsSection(title: L("launcher.search.panes")) {
            AgentSettingsRow(icon: "gearshape", title: L("launcher.search.panes.title"),
                             subtitle: L("launcher.search.panes.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: binding(\.settingsPanes)).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("launcher.search.panes.title"))
            }
        }
    }

    // MARK: - Files

    @ViewBuilder private var filesTab: some View {
        Section {
            AgentSettingsRow(icon: "doc.text.magnifyingglass", title: L("ask.settings.quick.files.title")) {
                Toggle("", isOn: Binding(get: { filesEnabled }, set: setFilesEnabled))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("ask.settings.quick.files.title"))
                    .accessibilityIdentifier("launcher.search.files.enabled")
            }
        }
        AgentSettingsSection(title: L("launcher.search.files.roots"), detail: "\(search.fileRoots.count)",
                             footnote: L("launcher.search.files.footnote")) {
            if search.fileRoots.isEmpty {
                AgentSettingsEmptyRow(text: L("launcher.search.files.empty"))
            }
            ForEach(search.fileRoots, id: \.self) { root in
                pathRow(root, icon: "folder") { update { $0.fileRoots.removeAll { $0 == root } } }
            }
            AgentSettingsActionRow(icon: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: false) {
                    update { $0.fileRoots = Self.adding(paths, to: $0.fileRoots) }
                }
            }
            HStack(spacing: 8) {
                quickAdd(L("launcher.search.files.icloud"), "~/Library/Mobile Documents")
                quickAdd(L("launcher.search.files.cloudStorage"), "~/Library/CloudStorage")
                Spacer()
                Button(L("launcher.search.reset")) {
                    update { $0.fileRoots = AskLauncherSearchSettings.defaultFileRoots }
                }
                .controlSize(.small)
            }
        }
        AgentSettingsSection(title: L("launcher.search.index")) {
            indexStatus
            HStack(spacing: 8) {
                Button(L("launcher.search.index.rebuild")) { index.rebuild() }
                    .disabled(!filesEnabled || status.isBuilding)
                Button(L("launcher.search.index.clear"), role: .destructive) { index.clear() }
                    .disabled(status.phase == .off)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var indexStatus: some View {
        HStack(spacing: 0) {
            statusCell(L("launcher.search.index.count"), status.count.formatted())
            statusCell(L("launcher.search.index.memory"), ByteCountFormatter.string(fromByteCount: Int64(status.bytes),
                                                                                    countStyle: .memory))
            statusCell(L("launcher.search.index.updated"),
                       status.updatedAt.map { AskQuickResultsView.relative($0) } ?? "—")
            statusCell(L("launcher.search.index.state"), Self.phaseText(status, enabled: filesEnabled))
        }
        .overlay(alignment: .bottom) {
            if let progress = status.progress {
                ProgressView(value: progress).progressViewStyle(.linear).padding(.horizontal, 18)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launcher.search.index.status")
    }

    static func phaseText(_ status: AskFileIndexStatus, enabled: Bool) -> String {
        guard enabled else { return L("launcher.search.index.off") }
        switch status.phase {
        case .off: return L("launcher.search.index.off")
        case .loading: return L("launcher.search.index.loading")
        case let .building(found, _): return L("launcher.search.index.building", found.formatted())
        case .ready: return L(status.truncated ? "launcher.search.index.truncated" : "launcher.search.index.live")
        }
    }

    private func statusCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundStyle(StudioTheme.textTertiary)
            Text(value).font(.body).foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickAdd(_ title: String, _ path: String) -> some View {
        Button("+ " + title) { update { $0.fileRoots = Self.adding([path], to: $0.fileRoots) } }
            .controlSize(.small)
            .disabled(search.fileRoots.contains(path))
    }
}

extension LauncherSearchSettingsView {
    // MARK: - Pieces

    func pathRow(_ path: String, icon: String, remove: @escaping () -> Void) -> some View {
        AgentSettingsRow(icon: icon, title: AskFileLabels.folder(path),
                         subtitle: path, subtitleLineLimit: 1) {
            TypefluxIconButton(L("ask.remove") + " " + path, systemImage: "minus", action: remove)
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AskLauncherSearchSettings, Value>) -> Binding<Value> {
        Binding(get: { search[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    /// Saves a change; the indexes follow the settings notification.
    func update(_ change: (inout AskLauncherSearchSettings) -> Void) {
        var next = search
        change(&next)
        guard next != search else { return }
        search = next
        settings.askLauncherSearchSettings = next
    }

    func setAppsEnabled(_ enabled: Bool) {
        appsEnabled = enabled
        settings.askQuickAppSearchEnabled = enabled
    }

    /// Reuses the existing preference and index lifecycle when file search changes.
    func setFilesEnabled(_ enabled: Bool) {
        filesEnabled = enabled
        settings.askQuickFileSearchEnabled = enabled
        index.start()
        status = index.status
    }

    func reload() {
        search = settings.askLauncherSearchSettings
        browserPreferences = settings.askBrowserSearchSettings
        appsEnabled = settings.askQuickAppSearchEnabled
        filesEnabled = settings.askQuickFileSearchEnabled
        previewEnabled = settings.askFilePreviewEnabled
        status = index.status
        let check = fullDiskAccess
        permissionTask?.cancel()
        permissionTask = Task {
            let granted = await Task.detached(priority: .utility) { check() }.value
            guard !Task.isCancelled else { return }
            hasFullDiskAccess = granted
        }
    }

    /// Paths with `~` for the home folder, added after the others without repeats.
    static func adding(_ paths: [String], to list: [String]) -> [String] {
        var result = list
        for path in paths.map({ AskLauncherSearchSettings.abbreviate($0) }) where !result.contains(path) {
            result.append(path)
        }
        return result
    }

    static func pickFolders(allowApps: Bool) -> [String]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowApps
        panel.allowedContentTypes = allowApps ? [.application] : []
        panel.allowsMultipleSelection = true
        panel.prompt = L("launcher.search.add")
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.map(\.path)
    }
}
