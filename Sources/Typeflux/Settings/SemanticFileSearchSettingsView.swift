import AppKit
import SwiftUI

/// The content index lives beside the file name index and shares its search scope.
struct SemanticFileSearchSettingsView: View {
    @ObservedObject var service: SemanticFileSearchService
    var filesEnabled: Bool
    @State private var confirmation: Deletion?
    @State private var isHovering = false
    @State private var showProcessingDetails = false

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
        let status = service.status(filesEnabled: filesEnabled)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TFStatusDot(level: Self.statusLevel(status.tone))
                Text(L("semantic.metrics"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    .accessibilityHint(L("semantic.subtitle"))
                SettingsDescriptionHint(detail: L("semantic.subtitle"), visible: isHovering)
                TFTag(text: L("semantic.index.badge"))
                TFTag(text: "Beta", tint: TFColors.accent)
                Spacer(minLength: 8)
                TFSwitch(title: L("semantic.title"), isOn: Binding(
                    get: { enabled },
                    set: { value in
                        if value {
                            enable()
                        } else {
                            service.setEnabled(false)
                            confirmation = nil
                        }
                    }
                ))
                .disabled(!service.supported || !filesEnabled || (!enabled && !hasScope))
                .accessibilityIdentifier("semantic.enabled")
            }
            detail
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .onHover { isHovering = $0 }
        .sheet(isPresented: $showProcessingDetails) {
            SemanticIndexDetailsView(service: service)
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
            Self.caption(L("semantic.index.off"))
            TFDivider(inset: 0)
            Text(L("semantic.index.setup"))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
            Self.caption(L(modelAvailable ? "semantic.index.setup.ready" : "semantic.index.setup.download"))
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFButton(title: L(modelAvailable ? "semantic.enable" : "semantic.enable.download"), kind: .primary,
                         action: enable)
                    .disabled(!filesEnabled || !hasScope)
                    .accessibilityIdentifier("semantic.setup.enable")
                TFButton(title: L("semantic.about"), kind: .link) {
                    NSWorkspace.shared.open(URL(string: "https://huggingface.co/google/embeddinggemma-2")!)
                }
            }
            if !hasScope {
                Self.caption(L("semantic.folders.empty"))
            }
            if !filesEnabled {
                Self.caption(L("semantic.filesOff"))
            }
        }
    }

    private var management: some View {
        let status = service.status(filesEnabled: filesEnabled)
        let storage = service.storage()
        return VStack(alignment: .leading, spacing: 12) {
            if !status.isPassiveWaiting {
                SemanticStatusLine(status: status)
                TFDivider(inset: 0)
            }
            if let reason = service.resourceWaitReason {
                Self.caption(L("semantic.wait." + reason.rawValue))
            }
            if let progress = status.progress {
                SemanticProgressView(progress: progress, detailed: true)
            }
            HStack(spacing: 20) {
                Self.metric(L("semantic.metric.files"), service.indexedCounts.files.formatted())
                Self.metric(L("semantic.metric.index"),
                            storage.index > 0 ? SemanticFileSearchStatus.size(storage.index) : "—")
                Self.metric(L("semantic.metric.model"),
                            service.modelReady && storage.model > 0 ? SemanticFileSearchStatus
                                .size(storage.model) : "—")
                Self.metric(L("semantic.metric.location"), L("semantic.metric.local"))
            }
            .accessibilityIdentifier("semantic.metrics")
            HStack(spacing: 20) {
                Self.metric(L("semantic.metric.documents"), service.indexedCounts.documents.formatted())
                Self.metric(L("semantic.metric.images"), service.indexedCounts.images.formatted())
                Self.metric(L("semantic.metric.audio"), service.indexedCounts.audio.formatted())
                Self.metric(L("semantic.metric.videos"), service.indexedCounts.videos.formatted())
            }
            .accessibilityIdentifier("semantic.fileTypes")
            if let diagnostics = service.diagnostics {
                SemanticIndexDiagnosticsView(diagnostics: diagnostics)
            }
            HStack(spacing: TFMetrics.toolbarSpacing) {
                lifecycleButton
                if service.phase != .ready && service.phase != .off {
                    Self.link(L("semantic.rescan")) { service.rescanAll() }
                        .disabled(!filesEnabled || !service.modelReady)
                }
                Self.link(L("semantic.details.open")) { showProcessingDetails = true }
                Self.destructiveLink(L("semantic.clear")) { confirmation = .index }
                Self.destructiveLink(L("semantic.remove")) { confirmation = .model }
                    .disabled(!service.modelReady)
            }
            .tfControlSize(.small)
            if status.action == .permission {
                permissionHelp
            }
            if let confirmation {
                TFInlineConfirmation(
                    title: L(confirmation == .model ? "semantic.remove.title" : "semantic.clear.title"),
                    message: L(confirmation == .model ? "semantic.remove.message" : "semantic.clear.message"),
                    confirmTitle: L(confirmation == .model ? "semantic.remove.confirm" : "semantic.clear.confirm"),
                    cancelTitle: L("semantic.cancel")
                ) {
                    Task { await service.clear(removeModel: confirmation == .model) }
                    self.confirmation = nil
                } onCancel: {
                    self.confirmation = nil
                }
                .accessibilityIdentifier("file.index.confirmation")
            }
        }
    }

    private var permissionHelp: some View {
        let folders = service.blocked.map { AskLauncherSearchSettings.abbreviate($0) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 8) {
            Self.caption(L("semantic.permission.message", folders))
            HStack(spacing: TFMetrics.toolbarSpacing) {
                Self.link(L("semantic.permission.open")) { NSWorkspace.shared.open(AskFullDiskAccess.settingsURL) }
                Self.link(L("semantic.permission.recheck")) { service.start(force: true) }
            }
            .tfControlSize(.small)
        }
    }

    @ViewBuilder private var lifecycleButton: some View {
        let active = service.preferences.enabled && filesEnabled
        switch service.phase {
        case .preparing:
            Self
                .link(L(service.manuallyPaused ? "semantic.resume" : "semantic.pause")) {
                    service.pause(!service.manuallyPaused)
                }
        case .downloading:
            Self.link(L("semantic.cancelDownload")) { service.cancelDownload() }
        case .indexing:
            Self.link(L("semantic.pause")) { service.pause(true) }
        case .paused:
            Self.link(L("semantic.resume")) { service.pause(false) }
        case .modelRequired:
            Self.link(L("semantic.download")) { service.downloadModel() }.disabled(!active)
        case .failed:
            Self.link(L(service.modelReady ? "semantic.retry" : "semantic.retryDownload")) {
                if service.modelReady {
                    service.start(force: true)
                } else {
                    service.downloadModel()
                }
            }.disabled(!active)
        case .ready, .off:
            Self.link(L("semantic.rescan")) { service.rescanAll() }
                .disabled(!active || !service.modelReady)
        }
    }

    private func enable() {
        guard service.setEnabled(true) else { return }
        Task { await service.prepareModelIfNeeded() }
    }

    static func metric(_ title: String, _ value: String) -> some View {
        TFMetric(title: title, value: value)
    }

    private static func statusLevel(_ tone: SemanticFileSearchStatus.Tone) -> TFStatusDot.Level {
        switch tone {
        case .off: .neutral
        case .busy: .accent
        case .ready: .success
        case .warning: .warning
        }
    }

    static func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A small secondary action in the index rows.
    static func link(_ title: String, action: @escaping () -> Void) -> some View {
        TFButton(title: title, action: action)
    }

    static func destructiveLink(_ title: String, action: @escaping () -> Void) -> some View {
        TFButton(title: title, destructive: true, action: action)
    }
}

/// A colored dot and the current content-index state.
struct SemanticStatusLine: View {
    let status: SemanticFileSearchStatus

    var body: some View {
        Text(status.text).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("semantic.status")
    }
}

/// Progress is shared by the inline index row and status tests.
struct SemanticProgressView: View {
    let progress: SemanticFileSearchStatus.Progress
    var detailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch progress {
            case let .download(fraction), let .mediaDownload(fraction):
                let media = if case .mediaDownload = progress {
                    true
                } else {
                    false
                }
                ProgressView(value: fraction).progressViewStyle(.linear)
                HStack {
                    Text(detailed ? SemanticFileSearchStatus.downloaded(
                        fraction, total: media ? SemanticMediaModel.bytes : SemanticModel.bytes
                    )
                        : L(media ? "semantic.media.downloading" : "semantic.progress.download"))
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%").monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
            case let .scanning(scanned, discovered):
                ProgressView().progressViewStyle(.linear)
                Text(L("semantic.progress.scanning", scanned.formatted(), discovered.formatted()))
                    .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
            case let .indexing(processed, total):
                let fraction = total > 0 ? min(1, Double(processed) / Double(total)) : 1
                ProgressView(value: fraction).progressViewStyle(.linear)
                HStack {
                    Text(L("semantic.progress.indexing", processed.formatted(), total.formatted()))
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%").monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
            case let .pausedScanning(scanned, discovered):
                Text(L("semantic.progress.scanningPaused", scanned.formatted(), discovered.formatted()))
                    .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
            case let .pausedIndexing(processed, total):
                Text(L("semantic.progress.indexing", processed.formatted(), total.formatted()))
                    .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
            }
        }
        .controlSize(.small)
    }
}
