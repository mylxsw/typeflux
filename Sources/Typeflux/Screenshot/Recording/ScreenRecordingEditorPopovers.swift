import SwiftUI

/// Speed presets for the recording editor; the chosen speed applies to preview and export.
struct ScreenRecordingSpeedMenu: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("recording.speed")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(ScreenRecordingEdit.rates, id: \.self) { rate in
                Button { model.setRate(rate); dismiss() } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(rate == model.edit.rate ? 1 : 0).frame(width: 14)
                        Text(ScreenRecordingEdit.rateTitle(rate)).font(.system(size: 13, design: .monospaced))
                        Spacer()
                        Text(L(Self.noteKey(rate))).foregroundStyle(StudioTheme.textTertiary)
                    }
                    .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            Text(L("recording.speedHint")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
        }
        .padding(10).frame(width: 270)
    }

    static func noteKey(_ rate: Double) -> String {
        rate == 1 ? "recording.speed.normal" : rate < 1 ? "recording.speed.slow" : "recording.speed.fast"
    }
}

/// One row per recorded audio source: include it in the export, and set its volume.
struct ScreenRecordingTrackMenu: View {
    @ObservedObject var model: ScreenRecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("recording.tracks")).font(.system(size: 13, weight: .semibold))
            Text(L("recording.tracksHint")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.edit.tracks) { track in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { track.included }, set: { model.setTrack(track.id, included: $0) })) {
                        Text(track.title).frame(width: 70, alignment: .leading)
                            .foregroundStyle(track.included ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel(L("recording.includeTrack", track.title))
                    Slider(value: Binding(get: { track.volume }, set: { model.setTrack(track.id, volume: $0) }),
                           in: 0 ... 1)
                        .controlSize(.small).disabled(!track.included)
                        .accessibilityLabel(L("recording.trackVolume", track.title))
                    Text("\(Int((track.volume * 100).rounded()))%").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioTheme.textTertiary).frame(width: 38, alignment: .trailing)
                }
            }
            if model.edit.includedTracks.isEmpty {
                Text(L("recording.tracksAllOff")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(width: 320)
    }
}

/// Lists the editor shortcuts handled by `ScreenRecordingWindowController.handleEditorKey`.
struct ScreenRecordingShortcutsView: View {
    static let rows: [(key: String, title: String)] = [
        ("Space", "recording.key.play"), ("I", "recording.key.in"), ("O", "recording.key.out"),
        ("← →", "recording.key.frame"), ("⇧ ← →", "recording.key.second"), ("[ ]", "recording.key.speed"),
        ("⌘S", "recording.key.save"), ("⇧⌘S", "recording.saveAs"), ("esc", "recording.key.close")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("recording.shortcuts")).font(.system(size: 13, weight: .semibold)).padding(.bottom, 3)
            ForEach(Self.rows, id: \.key) { row in
                HStack(spacing: 12) {
                    Text(row.key).font(.system(size: 11, weight: .medium)).padding(.horizontal, 6)
                        .frame(minWidth: 56, minHeight: 20)
                        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 5))
                    Text(L(row.title)).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
        .padding(14)
    }
}

/// "Save to" choices. A popover rather than an NSMenu, so the footer control keeps the shared button metrics.
struct ScreenRecordingDestinationMenu: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    let current: URL
    var chooseDirectory: () -> Void
    var saveAs: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("recording.destination")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(ScreenRecordingLayout.destinationFolders(current: current), id: \.self) { folder in
                row(ScreenRecordingPreviewView.folderName(folder), checked: folder == current) {
                    model.outputDirectory = folder
                }
                .help(folder.path)
            }
            Divider().padding(.vertical, 4)
            row(L("recording.chooseFolder"), checked: false, action: chooseDirectory)
                .accessibilityIdentifier("recording.preview.chooseFolder")
            row(L("recording.saveAs"), checked: false, shortcut: "⇧⌘S", action: saveAs)
                .disabled(!model.canExport)
                .accessibilityIdentifier("recording.preview.saveAs")
        }
        .padding(10).frame(width: 260)
    }

    private func row(_ title: String, checked: Bool, shortcut: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button { dismiss(); action() } label: {
            HStack {
                Image(systemName: "checkmark").opacity(checked ? 1 : 0).frame(width: 14)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(StudioTheme.textTertiary) }
            }
            .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact transport control that highlights when it holds a non-default value.
struct ScreenRecordingPillStyle: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9).frame(height: 26)
            .foregroundStyle(active ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .background(active ? AskTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? AskTheme.accent : AskTheme.border))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
