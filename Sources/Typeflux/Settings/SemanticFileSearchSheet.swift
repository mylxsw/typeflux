import AppKit
import SwiftUI

/// First-run setup and later management for the shared file-search scope.
struct SemanticFileSearchSheet: View {
    @ObservedObject var service: SemanticFileSearchService
    let setup: Bool
    let onClose: () -> Void
    @State private var deletion: Deletion?
    @State private var permission = false
    enum Deletion: String, Identifiable {
        case index, model
        var id: String { rawValue }
    }

    static let width: CGFloat = 560
    /// Rows shown before the folder list scrolls, so the sheet never outgrows the window.
    static let visibleFolders = 4

    init(service: SemanticFileSearchService, setup: Bool, onClose: @escaping () -> Void) {
        self.service = service; self.setup = setup; self.onClose = onClose
    }

    private var roots: [String] {
        SemanticFilePolicy.scope(names: self.service.settings.askLauncherSearchSettings, fullDiskAccess: true).roots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                AgentPaneHeader(
                    symbol: "sparkles",
                    title: L(self.setup ? "semantic.setup" : "semantic.manage.title"),
                    subtitle: L(self.setup ? "semantic.setup.subtitle" : "semantic.manage.subtitle")
                )
                if self.setup { self.setupContent } else { self.manageContent }
            }
            .padding(24)
            Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
            self.footer.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
        .background(StudioTheme.background)
        .alert(L(self.deletion == .model ? "semantic.remove.title" : "semantic.clear.title"), isPresented: Binding(
            get: { self.deletion != nil }, set: { if !$0 { self.deletion = nil } }
        ), presenting: self.deletion) { choice in
            Button(L("semantic.cancel"), role: .cancel) {}
            Button(L(choice == .model ? "semantic.remove.confirm" : "semantic.clear.confirm"), role: .destructive) {
                // Both actions turn content search off, so management has nothing left to show.
                Task { await self.service.clear(removeModel: choice == .model) }
                self.onClose()
            }
        } message: { choice in
            Text(L(choice == .model ? "semantic.remove.message" : "semantic.clear.message"))
        }
        .semanticPermissionAlert(isPresented: self.$permission, service: self.service)
    }

    // MARK: - Setup

    @ViewBuilder private var setupContent: some View {
        Self.notice {
            Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
            Text(L("semantic.privacy")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        self.folderSection
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: L("semantic.model"))
            ModelSurface {
                AgentSettingsRow(
                    icon: "cpu",
                    title: "EmbeddingGemma 2",
                    subtitle: L(self.service.modelReady ? "semantic.model.downloaded" : "semantic.model.download")
                ) {
                    ModelUsageBadge(text: L(self.service.modelReady
                            ? "semantic.model.downloadedBadge" : "semantic.model.badge"))
                }
            }
            Self.hint(L("semantic.model.help"))
        }
        Self.hint(L("semantic.priority"))
    }

    // MARK: - Manage

    @ViewBuilder private var manageContent: some View {
        let status = self.service.status()
        VStack(alignment: .leading, spacing: 10) {
            Self.notice {
                SemanticStatusLine(status: status)
                Spacer(minLength: 8)
                if status.action == .permission {
                    SemanticFileSearchSettingsView.link(L("semantic.checkPermission")) { self.permission = true }
                }
            }
            if let progress = status.progress {
                SemanticProgressView(progress: progress)
            }
        }
        self.folderSection
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(title: L("semantic.metrics"))
            ModelSurface { self.metrics }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                self.lifecycleButton
                Button { self.deletion = .index } label: {
                    Text(L("semantic.clear")).foregroundStyle(StudioTheme.danger)
                }
                Button { self.deletion = .model } label: {
                    Text(L("semantic.remove")).foregroundStyle(StudioTheme.danger)
                }
                .disabled(!self.service.modelReady)
            }
            .buttonStyle(ModelActionStyle())
            if self.service.limited {
                Text(L("semantic.limit")).font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            Self.hint(L("semantic.storage.help"))
        }
    }

    /// Pause or resume work in progress; otherwise retry a failure or rebuild a finished index.
    @ViewBuilder private var lifecycleButton: some View {
        let enabled = self.service.preferences.enabled && self.service.settings.askQuickFileSearchEnabled
        switch self.service.phase {
        case .downloading:
            Button(L("semantic.cancelDownload")) { self.service.cancelDownload() }
        case .indexing, .preparing:
            Button(L("semantic.pause")) { self.service.pause(true) }
        case .paused:
            Button(L("semantic.resume")) { self.service.pause(false) }
        case .modelRequired:
            Button(L("semantic.download")) { self.service.downloadModel() }.disabled(!enabled)
        case .failed:
            Button(L(self.service.modelReady ? "semantic.retry" : "semantic.retryDownload")) {
                if self.service.modelReady { self.service.start(force: true) } else { self.service.downloadModel() }
            }
            .disabled(!enabled)
        case .ready, .off:
            Button(L("semantic.rebuild")) { Task { await self.service.rebuild() } }
                .disabled(!enabled || !self.service.modelReady)
        }
    }

    private var metrics: some View {
        let storage = self.service.storage()
        return HStack(spacing: 0) {
            Self.metric(L("semantic.metric.files"), self.service.files.formatted())
            Self.metric(L("semantic.metric.index"),
                        storage.index > 0 ? SemanticFileSearchStatus.size(storage.index) : "—")
            Self.metric(L("semantic.metric.model"),
                        self.service.modelReady && storage.model > 0
                            ? SemanticFileSearchStatus.size(storage.model) : "—")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("semantic.metrics")
    }

    // MARK: - Shared

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelSectionLabel(
                title: L("semantic.folders"),
                detail: self.roots.isEmpty ? L("semantic.folders.none") : L("semantic.folders.count", self.roots.count)
            )
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    if self.roots.isEmpty {
                        AgentSettingsEmptyRow(text: L("semantic.folders.empty"))
                    } else if self.roots.count > Self.visibleFolders {
                        ScrollView { self.folderRows }.frame(height: CGFloat(Self.visibleFolders) * 69)
                    } else {
                        self.folderRows
                    }
                }
            }
            Self.hint(L("semantic.folders.help"))
        }
    }

    private var folderRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(self.roots.enumerated()), id: \.element) { index, root in
                if index > 0 { ModelRowDivider(leading: 66) }
                AgentSettingsRow(icon: "folder", title: AskFileLabels.folder(root),
                                 subtitle: AskLauncherSearchSettings.abbreviate(root))
                .help(root)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Link(L("semantic.about"), destination: URL(string: "https://huggingface.co/google/embeddinggemma-2")!)
                .font(.system(size: 12))
            Spacer()
            if self.setup {
                Button(L("semantic.cancel")) { self.onClose() }
                    .buttonStyle(ModelActionStyle()).keyboardShortcut(.cancelAction)
                Button(L(self.service.modelReady ? "semantic.enable" : "semantic.enable.download"), action: self.enable)
                    .buttonStyle(ModelActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(self.roots.isEmpty || !self.service.supported ||
                        !self.service.settings.askQuickFileSearchEnabled)
            } else {
                Button(L("semantic.close"), action: self.onClose)
                    .buttonStyle(ModelActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func enable() {
        guard self.service.setEnabled(true) else { return }
        self.onClose()
        Task {
            // Preparation verifies an existing model before deciding to download.
            await self.service.prepareModelIfNeeded()
        }
    }

    static func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }

    static func notice(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 42)
        .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ModelVisualStyle.border))
    }

    static func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
