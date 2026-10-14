import AppKit
import AVKit
import SwiftUI

struct ScreenRecordingView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var interfaceStyle
    @ObservedObject var model: ScreenRecordingCoordinator
    var close: () -> Void
    var chooseDirectory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(StudioTheme.danger).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.state == .setup {
                            HStack {
                                if model.permissionFailure != nil {
                                    Button(model.permissionActionTitle) { model.openPermissions() }
                                }
                                Button(L("recording.refresh")) { model.reloadChoices() }
                            }
                        }
                    }
                    content
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(16)
        }
        .font(.system(size: 13))
        .foregroundStyle(StudioTheme.textPrimary)
        .tint(AskTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .askInWindowGlass(corner: 12, opaqueFill: AskTheme.popoverSurface, elevation: nil, placement: .floating)
        .ignoresSafeArea()
        // Recreate native picker chrome when appearance changes; AppKit otherwise
        // keeps the previous appearance's label colours in a floating panel.
        .id("\(interfaceStyle.rawValue)-\(colorScheme)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.state == .paused ? "pause.circle.fill" : "record.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(model.state == .paused ? StudioTheme.warning : AskTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(model.state == .preview || model
                        .state == .exporting ? "recording.previewTitle" : "recording.title"))
                    .font(.system(size: 16, weight: .semibold))
                if model.state == .setup {
                    Text(L("recording.setupHint")).foregroundStyle(StudioTheme.textSecondary).font(.system(size: 12))
                }
            }
            Spacer(minLength: 8)
            if model.state == .recording || model.state == .paused {
                Text(ScreenRecordingCoordinator.timeLabel(model.elapsed)).monospacedDigit()
                    .font(.system(size: 22, weight: .medium)).accessibilityLabel(L("recording.elapsed"))
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .setup, .selecting: ScreenRecordingSetupView(model: model)
        case .countdown:
            Text(String(model.countdown)).font(.system(size: 48, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
            Text(L("recording.countdown")).foregroundStyle(StudioTheme.textSecondary)
            sourceSummary
        case .starting, .stopping:
            ProgressView(L(model.state == .starting ? "recording.starting" : "recording.stopping"))
                .frame(maxWidth: .infinity, minHeight: 60)
        case .recording, .paused:
            Label(L(model.state == .paused ? "recording.paused" : "recording.active"),
                  systemImage: model.state == .paused ? "pause.fill" : "record.circle.fill")
                .foregroundStyle(model.state == .paused ? StudioTheme.warning : StudioTheme.danger)
            sourceSummary
        case .preview, .exporting: ScreenRecordingPreviewView(model: model)
        case .completed:
            Label(L("recording.saved"), systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(StudioTheme.success)
            if let url = model.savedURL {
                Text(url.lastPathComponent).textSelection(.enabled)
                Text(url.deletingLastPathComponent().path).font(.caption)
                    .foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                HStack {
                    Button(L("recording.open")) { NSWorkspace.shared.open(url) }
                    Button(L("recording.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
    }

    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.sourceSummary, systemImage: model.selectedSource?.target.kind.symbol ?? "display")
                .lineLimit(2).help(model.sourceSummary)
            Label(model.audioSummary, systemImage: "speaker.wave.2")
            if model.options.camera {
                Label(L("recording.camera"), systemImage: "video")
            }
        }.font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
    }

    @ViewBuilder private var footer: some View {
        switch model.state {
        case .idle, .setup, .selecting:
            HStack {
                Button(L("recording.cancel"), action: close).keyboardShortcut(.cancelAction)
                if !model.recovered.isEmpty {
                    Menu(L("recording.recover")) {
                        ForEach(model.recovered, id: \.self) { url in
                            Button(ScreenRecordingCoordinator.recoveryTitle(url)) { model.recover(url) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                StudioButton(title: L("recording.start"), systemImage: "record.circle", variant: .primary,
                             isDisabled: !model.canStart) { model.start() }.keyboardShortcut(.defaultAction)
            }
        case .recording, .paused:
            HStack {
                Button(L(model.state == .paused ? "recording.resume" : "recording.pause")) { model.togglePause() }
                Menu {
                    Button(L("recording.discard"), role: .destructive, action: close)
                } label: { Image(systemName: "ellipsis") }
                    .fixedSize().accessibilityLabel(L("recording.more"))
                Spacer()
                StudioButton(title: L("recording.stop"), systemImage: "stop.fill", variant: .primary) { model.stop() }
            }
        case .preview:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("recording.destination"), systemImage: "folder")
                    Text(model.destinationDirectory.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(model.destinationDirectory.path)
                    Spacer()
                }.font(.caption).foregroundStyle(StudioTheme.textSecondary)
                HStack {
                    Button(L("recording.discard"), action: close)
                    Spacer()
                    Button(L("recording.saveAs"), action: chooseDirectory).disabled(!model.canExport)
                    StudioButton(title: L("recording.saveFormat", model.options.format.rawValue.uppercased()),
                                 systemImage: "square.and.arrow.down", variant: .primary,
                                 isDisabled: !model.canExport) { model.export() }.keyboardShortcut(.defaultAction)
                }
            }
        case .exporting:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("recording.exporting", model.options.format.rawValue.uppercased()))
                    Spacer()
                    Button(L("recording.cancelExport")) { model.cancelExport() }
                }
                ProgressView(value: model.progress)
            }
        case .completed:
            HStack { Spacer(); StudioButton(
                title: L("recording.done"),
                systemImage: nil,
                variant: .primary,
                action: close
            )
            .keyboardShortcut(.defaultAction)
            }
        case .countdown:
            HStack { Spacer(); Button(L("recording.cancel"), action: close).keyboardShortcut(.cancelAction) }
        case .starting, .stopping: EmptyView()
        }
    }
}

struct ScreenRecordingSection<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(AskTheme.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AskTheme.border))
    }
}
