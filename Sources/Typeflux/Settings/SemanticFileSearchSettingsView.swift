import AppKit
import SwiftUI

/// The disabled-by-default "Experimental" card on the launcher's Files tab.
struct SemanticFileSearchSettingsView: View {
    @ObservedObject var service: SemanticFileSearchService
    var filesEnabled: Bool
    let pickFolders: () -> [String]?
    @State private var presentation: Presentation?
    @State private var permission = false
    enum Presentation: String, Identifiable {
        case setup, manage
        var id: String { rawValue }
    }

    init(service: SemanticFileSearchService, filesEnabled: Bool,
         pickFolders: @escaping () -> [String]? = { LauncherSearchSettingsView.pickFolders(allowApps: false) }) {
        self.service = service; self.filesEnabled = filesEnabled; self.pickFolders = pickFolders
    }

    private var enabled: Bool { self.service.supported && self.service.preferences.enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: L("semantic.section"))
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    AgentSettingsRow(icon: "sparkles", title: L("semantic.title"), subtitle: L("semantic.subtitle"),
                                     badge: L("semantic.experimental"), badgeAccent: true, subtitleLineLimit: nil) {
                        Toggle("", isOn: Binding(
                            get: { self.enabled },
                            set: { enabled in
                                if enabled { self.presentation = .setup } else { self.service.setEnabled(false) }
                            }
                        ))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!self.service.supported || !self.filesEnabled)
                        .accessibilityLabel(L("semantic.title")).accessibilityIdentifier("semantic.enabled")
                    }
                    self.detail.padding(.leading, 66).padding(.trailing, 18).padding(.bottom, 16)
                }
            }
        }
        .sheet(item: self.$presentation) { mode in
            SemanticFileSearchSheet(service: self.service, setup: mode == .setup, pickFolders: self.pickFolders) {
                self.presentation = nil
            }
        }
        .semanticPermissionAlert(isPresented: self.$permission, service: self.service)
    }

    @ViewBuilder private var detail: some View {
        if !self.service.supported {
            Self.caption(L("semantic.unsupported"))
        } else {
            let status = self.service.status(filesEnabled: self.filesEnabled)
            VStack(alignment: .leading, spacing: 10) {
                if status.tone == .off {
                    Self.caption(status.text)
                } else {
                    SemanticStatusLine(status: status)
                    if let progress = status.progress {
                        SemanticProgressView(progress: progress, detailed: true)
                    }
                }
                if self.enabled {
                    HStack(spacing: 14) {
                        Button(L("semantic.manage")) { self.presentation = .manage }
                            .buttonStyle(ModelActionStyle())
                            .accessibilityIdentifier("semantic.manage")
                        if self.filesEnabled { self.action(status.action) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func action(_ action: SemanticFileSearchStatus.Action) -> some View {
        switch action {
        case .none: EmptyView()
        case .download: Self.link(L("semantic.download")) { self.service.downloadModel() }
        case .retryDownload: Self.link(L("semantic.retryDownload")) { self.service.downloadModel() }
        case .retry: Self.link(L("semantic.retry")) { self.service.start(force: true) }
        case .permission: Self.link(L("semantic.checkPermission")) { self.permission = true }
        }
    }

    static func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ModelVisualStyle.accent)
    }
}

/// A colored dot and the current state, e.g. "Ready · 1,248 files · 2,816 passages".
struct SemanticStatusLine: View {
    let status: SemanticFileSearchStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(self.color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0.height - 1 }
            Text(self.status.text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("semantic.status")
    }

    private var color: Color {
        switch self.status.tone {
        case .off: StudioTheme.textTertiary
        case .busy: ModelVisualStyle.accent
        case .ready: StudioTheme.success
        case .warning: StudioTheme.warning
        }
    }
}

/// Download progress is measured; indexing streams folders, so it has no known total.
struct SemanticProgressView: View {
    let progress: SemanticFileSearchStatus.Progress
    /// The settings card shows the downloaded size; the sheet names the stage instead.
    var detailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch self.progress {
            case let .download(fraction):
                ProgressView(value: fraction).progressViewStyle(.linear)
                HStack {
                    Text(self.detailed
                        ? SemanticFileSearchStatus.downloaded(fraction) : L("semantic.progress.download"))
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%").monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            case .indexing:
                ProgressView().progressViewStyle(.linear)
                if !self.detailed {
                    Text(L("semantic.progress.index")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }
        .controlSize(.small)
    }
}

extension View {
    /// Explains Full Disk Access for selected folders and rechecks once it is granted.
    func semanticPermissionAlert(isPresented: Binding<Bool>, service: SemanticFileSearchService) -> some View {
        let folders = service.blocked.map { AskLauncherSearchSettings.abbreviate($0) }.joined(separator: ", ")
        return alert(L("semantic.permission.title"), isPresented: isPresented) {
            Button(L("semantic.permission.recheck")) { service.start(force: true) }
            Button(L("semantic.permission.open")) { NSWorkspace.shared.open(AskFullDiskAccess.settingsURL) }
            Button(L("semantic.permission.later"), role: .cancel) {}
        } message: {
            Text(L("semantic.permission.message", folders))
        }
    }
}
