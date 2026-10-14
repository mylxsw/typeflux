import AppKit
import SwiftUI

/// The content index lives beside the file name index and shares its search scope.
struct SemanticFileSearchSettingsView: View {
    @ObservedObject var service: SemanticFileSearchService
    var filesEnabled: Bool
    @State private var confirmation: Deletion?

    enum Deletion { case index, model }

    private var enabled: Bool {
        service.supported && service.preferences.enabled
    }

    private var modelAvailable: Bool {
        service.modelReady || service.storage().model > 0
    }

    private var hasScope: Bool {
        !SemanticFilePolicy.scope(names: service.settings.askLauncherSearchSettings, fullDiskAccess: true).roots.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentSettingsRow(icon: "sparkles", title: L("semantic.metrics"), subtitle: L("semantic.subtitle"),
                             badge: L("semantic.experimental"), badgeAccent: true, subtitleLineLimit: nil) {
                if enabled || !service.supported {
                    Toggle("", isOn: Binding(
                        get: { enabled },
                        set: { value in
                            if !value {
                                service.setEnabled(false)
                                confirmation = nil
                            }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!service.supported || !filesEnabled)
                    .accessibilityLabel(L("semantic.title")).accessibilityIdentifier("semantic.enabled")
                } else {
                    Button(L(modelAvailable ? "semantic.enable" : "semantic.enable.download"), action: enable)
                        .buttonStyle(ModelActionStyle(primary: true))
                        .disabled(!filesEnabled || !hasScope)
                        .accessibilityIdentifier("semantic.setup.enable")
                }
            }
            detail.padding(.leading, 66).padding(.trailing, 18).padding(.bottom, 16)
        }
    }

    @ViewBuilder private var detail: some View {
        if !service.supported {
            Self.caption(L("semantic.unsupported"))
        } else if !enabled {
            setup
        } else {
            management
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Self.caption(L("semantic.privacy"))
            Self.caption(L(modelAvailable ? "semantic.model.downloaded" : "semantic.model.download"))
            Link(L("semantic.about"), destination: URL(string: "https://huggingface.co/google/embeddinggemma-2")!)
                .font(.system(size: 12))
            if !hasScope { Self.caption(L("semantic.folders.empty")) }
            if !filesEnabled { Self.caption(L("semantic.filesOff")) }
        }
    }

    private var management: some View {
        let status = service.status(filesEnabled: filesEnabled)
        let storage = service.storage()
        return VStack(alignment: .leading, spacing: 12) {
            SemanticStatusLine(status: status)
            if let progress = status.progress {
                SemanticProgressView(progress: progress, detailed: true)
            }
            HStack(spacing: 20) {
                metric(L("semantic.metric.files"), service.files.formatted())
                metric(L("semantic.metric.index"),
                       storage.index > 0 ? SemanticFileSearchStatus.size(storage.index) : "—")
                metric(L("semantic.metric.model"),
                       service.modelReady && storage.model > 0 ? SemanticFileSearchStatus.size(storage.model) : "—")
            }
            .accessibilityIdentifier("semantic.metrics")
            HStack(spacing: 14) {
                lifecycleButton
                Self.destructiveLink(L("semantic.clear")) { confirmation = .index }
                Self.destructiveLink(L("semantic.remove")) { confirmation = .model }
                    .disabled(!service.modelReady)
            }
            if status.action == .permission { permissionHelp }
            if service.limited { Self.caption(L("semantic.limit")) }
            if let confirmation {
                FileIndexInlineConfirmation(
                    title: L(confirmation == .model ? "semantic.remove.title" : "semantic.clear.title"),
                    message: L(confirmation == .model ? "semantic.remove.message" : "semantic.clear.message"),
                    confirm: L(confirmation == .model ? "semantic.remove.confirm" : "semantic.clear.confirm")
                ) {
                    Task { await service.clear(removeModel: confirmation == .model) }
                    self.confirmation = nil
                } onCancel: {
                    self.confirmation = nil
                }
            }
        }
    }

    private var permissionHelp: some View {
        let folders = service.blocked.map { AskLauncherSearchSettings.abbreviate($0) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 8) {
            Self.caption(L("semantic.permission.message", folders))
            HStack(spacing: 12) {
                Self.link(L("semantic.permission.open")) { NSWorkspace.shared.open(AskFullDiskAccess.settingsURL) }
                Self.link(L("semantic.permission.recheck")) { service.start(force: true) }
            }
        }
    }

    @ViewBuilder private var lifecycleButton: some View {
        let active = service.preferences.enabled && filesEnabled
        switch service.phase {
        case .downloading:
            Self.link(L("semantic.cancelDownload")) { service.cancelDownload() }
        case .indexing, .preparing:
            Self.link(L("semantic.pause")) { service.pause(true) }
        case .paused:
            Self.link(L("semantic.resume")) { service.pause(false) }
        case .modelRequired:
            Self.link(L("semantic.download")) { service.downloadModel() }.disabled(!active)
        case .failed:
            Self.link(L(service.modelReady ? "semantic.retry" : "semantic.retryDownload")) {
                if service.modelReady { service.start(force: true) } else { service.downloadModel() }
            }.disabled(!active)
        case .ready, .off:
            Self.link(L("semantic.rebuild")) { Task { await service.rebuild() } }
                .disabled(!active || !service.modelReady)
        }
    }

    private func enable() {
        guard service.setEnabled(true) else { return }
        Task { await service.prepareModelIfNeeded() }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ModelVisualStyle.accent)
    }

    static func destructiveLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, role: .destructive, action: action).buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(StudioTheme.danger)
    }
}

/// Confirms an index action in its row, without interrupting the settings page.
struct FileIndexInlineConfirmation: View {
    let title: String
    let message: String
    let confirm: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
            Text(message).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(confirm, role: .destructive, action: onConfirm).buttonStyle(ModelActionStyle())
                Button(L("semantic.cancel"), action: onCancel).buttonStyle(ModelActionStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("file.index.confirmation")
    }
}

/// A colored dot and the current content-index state.
struct SemanticStatusLine: View {
    let status: SemanticFileSearchStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0.height - 1 }
            Text(status.text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("semantic.status")
    }

    private var color: Color {
        switch status.tone {
        case .off: StudioTheme.textTertiary
        case .busy: ModelVisualStyle.accent
        case .ready: StudioTheme.success
        case .warning: StudioTheme.warning
        }
    }
}

/// Progress is shared by the inline index row and status tests.
struct SemanticProgressView: View {
    let progress: SemanticFileSearchStatus.Progress
    var detailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch progress {
            case let .download(fraction):
                ProgressView(value: fraction).progressViewStyle(.linear)
                HStack {
                    Text(detailed ? SemanticFileSearchStatus.downloaded(fraction) : L("semantic.progress.download"))
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%").monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            case let .scanning(scanned, discovered):
                ProgressView().progressViewStyle(.linear)
                Text(L("semantic.progress.scanning", scanned.formatted(), discovered.formatted()))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            case let .indexing(processed, total):
                let fraction = total > 0 ? min(1, Double(processed) / Double(total)) : 1
                ProgressView(value: fraction).progressViewStyle(.linear)
                HStack {
                    Text(L("semantic.progress.indexing", processed.formatted(), total.formatted()))
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%").monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .controlSize(.small)
    }
}
