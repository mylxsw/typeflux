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
    var semanticService: SemanticFileSearchService = .shared

    @State var tab: Tab = .general
    @State var search = AskLauncherSearchSettings()
    @State var appsEnabled = true
    @State var filesEnabled = true
    @State var previewEnabled = true
    @State var browserPreferences = AskBrowserSearchSettings()
    @State var status = AskFileIndexStatus()
    @State var hasFullDiskAccess = false
    @State private var confirmingNameIndexClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFPaneHeader(systemImage: LauncherSettingsPane.search.symbol, title: LauncherSettingsPane.search.title)
            TFTabBar(options: Tab.allCases.map { TFOption($0, $0.title) }, selection: $tab,
                     identifier: { "launcher.search.tab." + $0.rawValue })
                .accessibilityIdentifier("launcher.search.tabs")
            switch tab {
            case .general: generalTab
            case .apps: appsTab
            case .files: filesTab
            case .browsers: browsersTab
            case .exclude: excludeTab
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AskFileIndex.didChange)) { _ in status = index.status }
    }

    // MARK: - General

    @ViewBuilder private var generalTab: some View {
        TFFormSection(title: L("launcher.search.general")) {
            TFFormRow(title: L("launcher.search.preview"), detail: L("launcher.search.preview.subtitle"),
                      icon: "doc.viewfinder") {
                TFSwitch(title: L("launcher.search.preview"), isOn: Binding(get: { previewEnabled }, set: {
                    previewEnabled = $0; settings.askFilePreviewEnabled = $0
                }))
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("launcher.search.fuzzy"), detail: L("launcher.search.fuzzy.subtitle"),
                      icon: "wand.and.stars") {
                TFSwitch(title: L("launcher.search.fuzzy"), isOn: binding(\.fuzzy))
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("launcher.search.limit"), detail: L("launcher.search.limit.subtitle"), icon: "list.number") {
                TFPopUpButton(title: L("launcher.search.limit"),
                              options: AskLauncherSearchSettings.limits.map { TFOption($0, "\($0)") },
                              selection: binding(\.limit))
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("launcher.search.icons"), detail: L("launcher.search.icons.subtitle"), icon: "photo") {
                TFSegmentedControl(
                    options: AskLauncherSearchSettings.FileIcons.allCases.map {
                        TFOption($0, L("launcher.search.icons.\($0.rawValue)"))
                    },
                    selection: binding(\.fileIcons)
                )
                .accessibilityLabel(L("launcher.search.icons"))
            }
        }
        TFFormSection(title: L("launcher.search.permission")) {
            TFFormRow(title: L("launcher.search.fda"), detail: L("launcher.search.fda.subtitle"), icon: "lock.shield") {
                TFStatusLabel(text: L(hasFullDiskAccess ? "launcher.search.fda.granted" : "launcher.search.fda.missing"),
                              level: hasFullDiskAccess ? .success : .neutral)
                if !hasFullDiskAccess {
                    TFButton(title: L("launcher.search.fda.open")) { NSWorkspace.shared.open(AskFullDiskAccess.settingsURL) }
                }
            }
        }
    }

    // MARK: - Applications

    @ViewBuilder private var appsTab: some View {
        TFFormSection {
            TFFormRow(title: L("ask.settings.quick.apps.title"), icon: "square.grid.2x2") {
                TFSwitch(title: L("ask.settings.quick.apps.title"),
                         isOn: Binding(get: { appsEnabled }, set: setAppsEnabled))
                    .accessibilityIdentifier("launcher.search.apps.enabled")
            }
        }
        TFFormSection(title: L("launcher.search.apps.roots"), count: search.appRoots.count,
                      footnote: L("launcher.search.apps.footnote")) {
            ForEach(search.appRoots, id: \.self) { root in
                pathRow(root, icon: root.hasSuffix(".app") ? "app" : "folder") {
                    update { $0.appRoots.removeAll { $0 == root } }
                }
                TFDivider.formWithIcon
            }
            TFActionRow(systemImage: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: true) {
                    update { $0.appRoots = Self.adding(paths, to: $0.appRoots) }
                }
            }
            TFDivider.formWithIcon
            TFActionRow(systemImage: "arrow.counterclockwise", title: L("launcher.search.reset")) {
                update { $0.appRoots = AskLauncherSearchSettings.defaultAppRoots }
            }
        }
        TFFormSection(title: L("launcher.search.panes")) {
            TFFormRow(title: L("launcher.search.panes.title"), detail: L("launcher.search.panes.subtitle"),
                      icon: "gearshape") {
                TFSwitch(title: L("launcher.search.panes.title"), isOn: binding(\.settingsPanes))
            }
        }
    }

    // MARK: - Files

    @ViewBuilder private var filesTab: some View {
        TFFormSection {
            TFFormRow(title: L("ask.settings.quick.files.title"), icon: "doc.text.magnifyingglass") {
                TFSwitch(title: L("ask.settings.quick.files.title"),
                         isOn: Binding(get: { filesEnabled }, set: setFilesEnabled))
                    .accessibilityIdentifier("launcher.search.files.enabled")
            }
        }
        TFFormSection(title: L("launcher.search.files.roots"), count: search.fileRoots.count,
                      footnote: L("launcher.search.files.exclusionsHint")) {
            if search.fileRoots.isEmpty {
                TFCardNote(text: L("launcher.search.files.empty"))
                TFDivider.form
            }
            ForEach(search.fileRoots, id: \.self) { root in
                pathRow(root, icon: "folder") { update { $0.fileRoots.removeAll { $0 == root } } }
                TFDivider.formWithIcon
            }
            TFActionRow(systemImage: "plus", title: L("launcher.search.files.addFolder")) {
                if let paths = Self.pickFolders(allowApps: false) {
                    update { $0.fileRoots = Self.adding(paths, to: $0.fileRoots) }
                }
            }
            TFDivider.formWithIcon
            TFActionRow(systemImage: "arrow.counterclockwise", title: L("launcher.search.reset")) {
                update { $0.fileRoots = AskLauncherSearchSettings.defaultFileRoots }
            }
        }
        TFFormSection(title: L("launcher.search.index")) {
            nameIndexRow
            TFDivider.form
            SemanticFileSearchSettingsView(service: semanticService, filesEnabled: filesEnabled)
        }
    }

    private var nameIndexRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TFStatusDot(level: filesEnabled ? .success : .neutral)
                Text(L("launcher.search.index.name"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                Spacer(minLength: 8)
                Text(Self.phaseText(status, enabled: filesEnabled))
                    .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
            }
            Text(L("launcher.search.index.name.subtitle")).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                TFMetric(title: L("launcher.search.index.count"), value: status.count.formatted())
                TFMetric(title: L("launcher.search.index.memory"),
                         value: ByteCountFormatter.string(fromByteCount: Int64(status.bytes), countStyle: .memory))
                TFMetric(title: L("launcher.search.index.updated"),
                         value: status.updatedAt.map { AskQuickResultsView.relative($0) } ?? "—")
            }
            .accessibilityIdentifier("launcher.search.index.metrics")
            if let progress = status.progress {
                ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
            }
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFButton(title: L("launcher.search.index.rebuild"), systemImage: "arrow.clockwise", size: .small) {
                    index.rebuild()
                }
                .disabled(!filesEnabled || status.isBuilding)
                TFButton(title: L("launcher.search.index.clear"), destructive: true, size: .small) {
                    confirmingNameIndexClear = true
                }
                .disabled(status.phase == .off)
            }
            if confirmingNameIndexClear {
                TFInlineConfirmation(title: L("launcher.search.index.clear.title"),
                                     message: L("launcher.search.index.clear.message"),
                                     confirmTitle: L("launcher.search.index.clear.confirm")) {
                    index.clear()
                    confirmingNameIndexClear = false
                } onCancel: {
                    confirmingNameIndexClear = false
                }
                .accessibilityIdentifier("file.index.confirmation")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
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

    // MARK: - Exclusions

    @ViewBuilder private var excludeTab: some View {
        TFFormSection(title: L("launcher.search.exclude.paths"), count: search.excludedPaths.count) {
            ForEach(search.excludedPaths, id: \.self) { path in
                pathRow(path, icon: "folder.badge.minus") { update { $0.excludedPaths.removeAll { $0 == path } } }
                TFDivider.formWithIcon
            }
            TFActionRow(systemImage: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: false) {
                    update { $0.excludedPaths = Self.adding(paths, to: $0.excludedPaths) }
                }
            }
        }
        TFFormSection(title: L("launcher.search.exclude.types"), count: search.excludedExtensions.count) {
            TFTokenInput(values: search.excludedExtensions, placeholder: L("launcher.search.exclude.types.placeholder"),
                         addTitle: L("launcher.search.add"), normalize: AskLauncherSearchSettings.cleanExtension) { values in
                update { $0.excludedExtensions = values }
            }
        }
        TFFormSection(title: L("launcher.search.exclude.names"), count: search.excludedFolderNames.count) {
            TFTokenInput(values: search.excludedFolderNames, placeholder: L("launcher.search.exclude.names.placeholder"),
                         addTitle: L("launcher.search.add"), normalize: AskLauncherSearchSettings.cleanFolderName) { values in
                update { $0.excludedFolderNames = values }
            }
        }
        TFFormSection(title: L("launcher.search.exclude.more"), footnote: L("launcher.search.exclude.footnote")) {
            TFFormRow(title: L("launcher.search.hidden"), detail: L("launcher.search.hidden.subtitle"), icon: "eye.slash") {
                TFSwitch(title: L("launcher.search.hidden"), isOn: binding(\.includeHidden))
            }
            TFDivider.formWithIcon
            TFActionRow(systemImage: "arrow.counterclockwise", title: L("launcher.search.reset")) {
                update {
                    $0.excludedPaths = AskLauncherSearchSettings.defaultExcludedPaths
                    $0.excludedExtensions = []
                    $0.excludedFolderNames = AskLauncherSearchSettings.defaultExcludedFolderNames
                    $0.includeHidden = false
                }
            }
        }
    }
}

extension LauncherSearchSettingsView {
    // MARK: - Pieces

    private func pathRow(_ path: String, icon: String, remove: @escaping () -> Void) -> some View {
        TFFormRow(title: AskFileLabels.folder(path), detail: path, icon: icon, detailLineLimit: 1) {
            TFButton(title: L("ask.remove"), systemImage: "minus", size: .small, iconOnly: true, action: remove)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AskLauncherSearchSettings, Value>) -> Binding<Value> {
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
        Task {
            let granted = await Task.detached(priority: .utility) { check() }.value
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
