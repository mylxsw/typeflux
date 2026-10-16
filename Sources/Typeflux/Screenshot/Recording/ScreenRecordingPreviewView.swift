import AppKit
import SwiftUI

struct ScreenRecordingPreviewView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var saveAs: () -> Void = {}

    var body: some View {
        Group {
            if model.canUsePreview { content }
            else { Text(L("recording.previewUnavailable")).padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                TextField(L("recording.fileName"), text: $model.fileName).textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold)).frame(width: min(
                        420,
                        max(
                            120,
                            (model.fileName as NSString).size(withAttributes: [.font: NSFont.systemFont(
                                ofSize: 13,
                                weight: .semibold
                            )]).width + 12
                        )
                    ))
                    .accessibilityIdentifier("recording.fileName")
                Text("." + model.options.format.rawValue).foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                ScreenRecordingPreviewVolume(playback: model.playback).frame(width: 85)
                Picker(L("recording.format"), selection: $model.options.format) {
                    Text("MP4").tag(ScreenRecordingFormat.mp4); Text("GIF").tag(ScreenRecordingFormat.gif)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 128)
            }.padding(.leading, 78).padding(.trailing, 14).frame(height: 46).disabled(model.state == .exporting)
            Divider()
            ZStack {
                ScreenRecordingPlayerView(playback: model.playback)
                if !model.isPlaying, model.playback.isLoaded {
                    Button(action: model.togglePlayback) {
                        Image(systemName: "play.fill").font(.system(size: 22)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(.black.opacity(0.6), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel(L("recording.play"))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 200)
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 10) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(L("recording.play")).disabled(!model.playback.isLoaded || model.playback.isBusy)
                Text(ScreenRecordingLayout.preciseTime(model.currentTime) + " / " + ScreenRecordingLayout
                    .preciseTime(model.duration))
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text(L("recording.source." + model.sourceKind.rawValue) + " · " + model
                    .audioSummary + (model.options.camera ? " · " + L("recording.camera") : ""))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }.padding(.horizontal, 16).padding(.top, 8).frame(height: 28)
            ScreenRecordingTimelineView(model: model).frame(height: 104).padding(.horizontal, 16).padding(.top, 8)
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                Text(L("recording.keepRange"))
                Text(ScreenRecordingLayout.preciseTime(model.trimStart) + " – " + ScreenRecordingLayout
                    .preciseTime(model.trimEnd)).fontWeight(.semibold).monospacedDigit()
                Text(L("recording.selectionSeconds", model.selectionDuration))
                Button(L("recording.resetTrim"), action: model.resetTrim)
                    .buttonStyle(AskWorkflowActionStyle(kind: .ghost, small: true))
                Spacer()
                Text(L("recording.timelineKeys")).foregroundStyle(StudioTheme.textTertiary).font(.system(size: 11))
            }.font(.system(size: 12)).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
            if model.options.format == .gif, model.selectionDuration > 30.01 {
                HStack(spacing: 8) {
                    Label(L("recording.gifTooLong"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StudioTheme.warning)
                    Spacer()
                    Button(L("recording.keep30"), action: model.keepFirstGIFSegment)
                    Button(L("recording.switchMP4")) { model.options.format = .mp4 }
                }.buttonStyle(ModelActionStyle()).font(.system(size: 12)).padding(8).background(
                    StudioTheme.warning.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(StudioTheme.danger)
                    .font(.system(size: 12)).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if model.sourceURL != nil {
                Button(L("recording.revealOriginal"), action: model.revealOriginal).disabled(!model.canUsePreview)
                    .font(.caption).padding(.bottom, 6)
                if !model.playback.isLoaded, model.state == .preview {
                    Button(L("recording.reloadPreview"), action: model.reloadPreviewPlayback)
                        .disabled(!model.canUsePreview || model.playback.isBusy)
                }
            }
            Divider()
            footer.frame(height: 58).padding(.horizontal, 14)
        }.font(.system(size: 13)).foregroundStyle(StudioTheme.textPrimary).tint(AskTheme.accent)
            .askInWindowGlass(corner: 12, opaqueFill: AskTheme.surface, elevation: nil, placement: .floating)
            .ignoresSafeArea()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Label(L("recording.discard"), systemImage: "trash")
                    .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(StudioTheme.danger)
            .accessibilityIdentifier("recording.preview.discard")
            Text(model.options.format.rawValue
                .uppercased() +
                " · \(Int(model.previewOutputSize.width)) × \(Int(model.previewOutputSize.height)) · \(model.options.captureFPS) FPS · " +
                L(
                    "recording.estimated",
                    ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file)
                ))
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            Spacer(minLength: 2)
            if model.state == .exporting {
                ScreenRecordingExportProgress(progress: model.progress, format: model.options.format).frame(
                    width: 230,
                    height: 30
                )
                Button(L("recording.cancelExport"), action: model.cancelExport)
                    .accessibilityIdentifier("recording.preview.cancelExport")
            } else {
                Button(action: chooseDirectory) {
                    Label {
                        Text(model.destinationDirectory.lastPathComponent)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 110)
                            .fixedSize(horizontal: true, vertical: false)
                    } icon: { Image(systemName: "folder") }
                }
                .help(model.destinationDirectory.path)
                .accessibilityIdentifier("recording.preview.directory")
                Button { model.export(copy: true) } label: { Label(L("recording.copy"), systemImage: "doc.on.doc") }
                    .disabled(!model.canExport)
                    .accessibilityIdentifier("recording.preview.copy")
                Button(L("recording.saveAs"), action: saveAs).disabled(!model.canExport)
                    .accessibilityIdentifier("recording.preview.saveAs")
                Button { model.export() } label: {
                    HStack(spacing: 6) {
                        Label(
                            L("recording.saveFormat", model.options.format.rawValue.uppercased()),
                            systemImage: "checkmark"
                        )
                        Text("⌘S").font(.system(size: 11)).opacity(0.75)
                    }
                }.buttonStyle(ModelActionStyle(primary: true)).disabled(!model.canExport)
                    .accessibilityIdentifier("recording.preview.save")
                    .keyboardShortcut("s", modifiers: .command)
            }
        }.buttonStyle(ModelActionStyle())
    }
}

struct ScreenRecordingPlayerView: View {
    @ObservedObject var playback: ClipboardAudioPlayback
    var body: some View {
        ZStack {
            Color.black
            if let image = playback.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Text(L("recording.previewUnavailable")).font(.caption).foregroundStyle(.white).padding() }
        }
    }
}

private struct ScreenRecordingPreviewVolume: View {
    @ObservedObject var playback: ClipboardAudioPlayback
    @State private var value = 1.0
    @State private var interaction: UUID?
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
            Slider(value: $value, in: 0...1) { editing in
                if editing { interaction = playback.interactionID }
                else if let token = interaction {
                    interaction = nil; playback.setVolume(value, interactionID: token)
                }
            }.accessibilityLabel(L("clipboard.video.volume"))
        }.disabled(!playback.isLoaded || playback.isBusy)
            .onChange(of: playback.volume) { if interaction == nil { value = $0 } }
    }
}

struct ScreenRecordingExportProgress: View {
    var progress: Double
    var format: ScreenRecordingFormat
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(AskTheme.controlSurface)
                RoundedRectangle(cornerRadius: 8).fill(AskTheme.accentSoft)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
                Text(L("recording.exporting", format.rawValue.uppercased()) +
                    " · \(Int(min(1, max(0, progress)) * 100))%")
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10)
            }
        }.accessibilityValue("\(Int(min(1, max(0, progress)) * 100))%")
    }
}
