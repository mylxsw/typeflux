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
    @State private var newExtension = ""
    @State private var newFolderName = ""
    @State private var confirmingNameIndexClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentPaneHeader(symbol: LauncherSettingsPane.search.symbol, title: LauncherSettingsPane.search.title)
            StudioSegmentedControl(options: Tab.allCases.map { (label: $0.title, value: $0) }, selection: $tab)
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
        AgentSettingsSection(title: L("launcher.search.general")) {
            AgentSettingsRow(icon: "doc.viewfinder", title: L("launcher.search.preview"),
                             subtitle: L("launcher.search.preview.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: Binding(get: { previewEnabled }, set: {
                    previewEnabled = $0; settings.askFilePreviewEnabled = $0
                })).labelsHidden().toggleStyle(.switch).accessibilityLabel(L("launcher.search.preview"))
            }
            ModelRowDivider(leading: 66)
            AgentSettingsRow(icon: "wand.and.stars", title: L("launcher.search.fuzzy"),
                             subtitle: L("launcher.search.fuzzy.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: binding(\.fuzzy)).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("launcher.search.fuzzy"))
            }
            ModelRowDivider(leading: 66)
            AgentSettingsRow(icon: "list.number", title: L("launcher.search.limit"),
                             subtitle: L("launcher.search.limit.subtitle"), subtitleLineLimit: nil) {
                SettingsMenuPicker(title: L("launcher.search.limit"),
                                   options: AskLauncherSearchSettings.limits.map { (label: "\($0)", value: $0) },
                                   selection: binding(\.limit))
                    .frame(width: 90)
            }
            ModelRowDivider(leading: 66)
            AgentSettingsRow(icon: "photo", title: L("launcher.search.icons"),
                             subtitle: L("launcher.search.icons.subtitle"), subtitleLineLimit: nil) {
                StudioSegmentedControl(
                    options: AskLauncherSearchSettings.FileIcons.allCases.map { (
                        label: L("launcher.search.icons.\($0.rawValue)"),
                        value: $0
                    ) },
                    selection: binding(\.fileIcons), size: .compact
                )
                .accessibilityLabel(L("launcher.search.icons"))
            }
        }
        AgentSettingsSection(title: L("launcher.search.permission")) {
            AgentSettingsRow(icon: "lock.shield", title: L("launcher.search.fda"),
                             subtitle: L("launcher.search.fda.subtitle"), subtitleLineLimit: nil) {
                HStack(spacing: 10) {
                    Circle().fill(hasFullDiskAccess ? StudioTheme.success : StudioTheme.textTertiary)
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(L(hasFullDiskAccess ? "launcher.search.fda.granted" : "launcher.search.fda.missing"))
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
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
        ModelSurface {
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
                ModelRowDivider(leading: 66)
            }
            AgentSettingsActionRow(icon: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: true) {
                    update { $0.appRoots = Self.adding(paths, to: $0.appRoots) }
                }
            }
            ModelRowDivider(leading: 66)
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
        ModelSurface {
            HStack(spacing: 16) {
                Text(L("ask.settings.quick.files.title"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { filesEnabled }, set: setFilesEnabled))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("ask.settings.quick.files.title"))
                    .accessibilityIdentifier("launcher.search.files.enabled")
            }
            .padding(.horizontal, 20).padding(.vertical, 19)
        }
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: L("launcher.search.files.roots"))
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    if search.fileRoots.isEmpty {
                        AgentSettingsEmptyRow(text: L("launcher.search.files.empty"))
                    }
                    ForEach(search.fileRoots, id: \.self) { root in
                        if root != search.fileRoots.first { ModelRowDivider(leading: 18) }
                        compactFileRoot(root)
                    }
                    ModelRowDivider(leading: 18)
                    HStack(spacing: 14) {
                        SemanticFileSearchSettingsView.link(L("launcher.search.files.addFolder")) {
                            if let paths = Self.pickFolders(allowApps: false) {
                                update { $0.fileRoots = Self.adding(paths, to: $0.fileRoots) }
                            }
                        }
                        SemanticFileSearchSettingsView.link(L("launcher.search.reset")) {
                            update { $0.fileRoots = AskLauncherSearchSettings.defaultFileRoots }
                        }
                        Spacer(minLength: 8)
                        Text(L("launcher.search.files.exclusionsHint"))
                            .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: L("launcher.search.index"))
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    nameIndexRow
                    ModelRowDivider(leading: 18)
                    SemanticFileSearchSettingsView(service: semanticService, filesEnabled: filesEnabled)
                }
            }
        }
    }

    private func compactFileRoot(_ root: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 15)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 34, height: 34)
                .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(AskFileLabels.folder(root)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(root).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SemanticFileSearchSettingsView.link(L("ask.remove")) {
                update { $0.fileRoots.removeAll { $0 == root } }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var nameIndexRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(filesEnabled ? StudioTheme.success : StudioTheme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(L("launcher.search.index.name"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Spacer(minLength: 8)
                Text(Self.phaseText(status, enabled: filesEnabled))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            SemanticFileSearchSettingsView.caption(L("launcher.search.index.name.subtitle"))
            HStack(spacing: 20) {
                SemanticFileSearchSettingsView.metric(L("launcher.search.index.count"), status.count.formatted())
                SemanticFileSearchSettingsView.metric(
                    L("launcher.search.index.memory"),
                    ByteCountFormatter.string(fromByteCount: Int64(status.bytes), countStyle: .memory)
                )
                SemanticFileSearchSettingsView.metric(
                    L("launcher.search.index.updated"),
                    status.updatedAt.map { AskQuickResultsView.relative($0) } ?? "—"
                )
            }
            .accessibilityIdentifier("launcher.search.index.metrics")
            if let progress = status.progress {
                ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
            }
            HStack(spacing: 14) {
                SemanticFileSearchSettingsView.link(L("launcher.search.index.rebuild")) { index.rebuild() }
                    .disabled(!filesEnabled || status.isBuilding)
                SemanticFileSearchSettingsView.destructiveLink(L("launcher.search.index.clear")) {
                    confirmingNameIndexClear = true
                }.disabled(status.phase == .off)
            }
            if confirmingNameIndexClear {
                FileIndexInlineConfirmation(title: L("launcher.search.index.clear.title"),
                                            message: L("launcher.search.index.clear.message"),
                                            confirm: L("launcher.search.index.clear.confirm")) {
                    index.clear()
                    confirmingNameIndexClear = false
                } onCancel: {
                    confirmingNameIndexClear = false
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
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
        AgentSettingsSection(title: L("launcher.search.exclude.paths"), detail: "\(search.excludedPaths.count)") {
            ForEach(search.excludedPaths, id: \.self) { path in
                pathRow(path, icon: "folder.badge.minus") { update { $0.excludedPaths.removeAll { $0 == path } } }
                ModelRowDivider(leading: 66)
            }
            AgentSettingsActionRow(icon: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: false) {
                    update { $0.excludedPaths = Self.adding(paths, to: $0.excludedPaths) }
                }
            }
        }
        tagSection(title: L("launcher.search.exclude.types"), values: search.excludedExtensions,
                   placeholder: L("launcher.search.exclude.types.placeholder"), text: $newExtension,
                   clean: AskLauncherSearchSettings
                       .cleanExtension) { values in update { $0.excludedExtensions = values } }
        tagSection(title: L("launcher.search.exclude.names"), values: search.excludedFolderNames,
                   placeholder: L("launcher.search.exclude.names.placeholder"), text: $newFolderName,
                   clean: AskLauncherSearchSettings
                       .cleanFolderName) { values in update { $0.excludedFolderNames = values } }
        AgentSettingsSection(title: L("launcher.search.exclude.more"),
                             footnote: L("launcher.search.exclude.footnote")) {
            AgentSettingsRow(icon: "eye.slash", title: L("launcher.search.hidden"),
                             subtitle: L("launcher.search.hidden.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: binding(\.includeHidden)).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("launcher.search.hidden"))
            }
            ModelRowDivider(leading: 66)
            AgentSettingsActionRow(icon: "arrow.counterclockwise", title: L("launcher.search.reset")) {
                update {
                    $0.excludedPaths = AskLauncherSearchSettings.defaultExcludedPaths
                    $0.excludedExtensions = []
                    $0.excludedFolderNames = AskLauncherSearchSettings.defaultExcludedFolderNames
                    $0.includeHidden = false
                }
            }
        }
    }

    private func tagSection(title: String, values: [String], placeholder: String, text: Binding<String>,
                            clean: @escaping (String) -> String?, save: @escaping ([String]) -> Void) -> some View {
        AgentSettingsSection(title: title, detail: "\(values.count)") {
            VStack(alignment: .leading, spacing: 10) {
                if !values.isEmpty {
                    AgentFlowLayout(spacing: 6) {
                        ForEach(values, id: \.self) { value in
                            HStack(spacing: 4) {
                                Text(value).font(.system(size: 12, design: .monospaced))
                                Button { save(values.filter { $0 != value }) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                                .accessibilityLabel(L("ask.remove"))
                            }
                            .padding(.leading, 8).padding(.trailing, 6).frame(height: 22)
                            .background(
                                ModelVisualStyle.control,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField(placeholder, text: text).textFieldStyle(ModelFieldStyle()).frame(maxWidth: 240)
                        .onSubmit { add(text, clean: clean, to: values, save: save) }
                    Button(L("launcher.search.add")) { add(text, clean: clean, to: values, save: save) }
                        .controlSize(.small)
                        .disabled(clean(text.wrappedValue) == nil)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private func add(
        _ text: Binding<String>,
        clean: (String) -> String?,
        to values: [String],
        save: ([String]) -> Void
    ) {
        guard let value = clean(text.wrappedValue) else { return }
        if !values.contains(value) {
            save(values + [value])
        }
        text.wrappedValue = ""
    }
}

extension LauncherSearchSettingsView {
    // MARK: - Pieces

    private func pathRow(_ path: String, icon: String, remove: @escaping () -> Void) -> some View {
        return AgentSettingsRow(icon: icon, title: AskFileLabels.folder(path),
                                subtitle: path, subtitleLineLimit: 1) {
            AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove"), action: remove)
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
