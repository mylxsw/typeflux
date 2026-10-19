import AppKit
import SwiftUI

struct ScreenRecordingPreviewView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var saveAs: () -> Void = {}
    @State private var showsShortcuts = false
    @State private var showsSpeed = false
    @State private var showsTracks = false
    @State private var showsDestinations = false
    @State private var stageHover = false
    @State private var showsShortcutHints = false

    var body: some View {
        Group {
            if model.canUsePreview { content }
            else { Text(L("recording.previewUnavailable")).padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(AskLauncherCommandMonitor { showsShortcutHints = $0 })
    }

    private var content: some View {
        VStack(spacing: 0) {
            header.frame(height: 46).disabled(model.state == .exporting)
            stage
            transport.padding(.horizontal, 14).frame(height: 40)
            ScreenRecordingTimelineView(model: model).padding(.horizontal, 16).padding(.top, 4)
            ScreenRecordingTrimBar(model: model, showsShortcutHints: showsShortcutHints)
                .padding(.horizontal, 16).frame(height: 44)
            if model.gifTooLong {
                ScreenRecordingGIFLimitBanner(model: model).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(StudioTheme.danger)
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(AskTheme.dangerSoft, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            footer.frame(height: 60).padding(.horizontal, 14)
        }.font(.system(size: 13)).foregroundStyle(StudioTheme.textPrimary).tint(AskTheme.accent)
            .askInWindowGlass(corner: 12, opaqueFill: AskTheme.surface, elevation: nil, placement: .floating)
            .ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                TextField(L("recording.fileName"), text: $model.fileName).textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold)).frame(width: fileNameWidth)
                    .accessibilityIdentifier("recording.fileName")
                Text("." + model.options.format.rawValue).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 6).frame(height: 26)
            .background(AskTheme.controlSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Label(sourceSummary, systemImage: model.sourceKind.symbol)
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 22).background(AskTheme.controlSurface, in: Capsule())
            Spacer(minLength: 8)
            Button { showsShortcuts.toggle() } label: {
                Image(systemName: "keyboard").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary).help(L("recording.shortcuts"))
            .accessibilityLabel(L("recording.shortcuts"))
            .popover(isPresented: $showsShortcuts, arrowEdge: .bottom) { ScreenRecordingShortcutsView() }
            Menu {
                Button(L("recording.revealOriginal"), action: model.revealOriginal).disabled(model.sourceURL == nil)
                Button(L("recording.reloadPreview"), action: model.reloadPreviewPlayback)
                    .disabled(model.sourceURL == nil || model.playback.isBusy)
                Divider()
                Button(L("recording.shortcuts")) { showsShortcuts = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("recording.more"))
                .accessibilityLabel(L("recording.more"))
        }
        .padding(.leading, 78).padding(.trailing, 14)
    }

    private var fileNameWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return min(380, max(120, (model.fileName as NSString).size(withAttributes: [.font: font]).width + 12))
    }

    private var sourceSummary: String {
        var parts = [L("recording.source." + model.sourceKind.rawValue)]
        if model.options.camera { parts.append(L("recording.camera")) }
        let size = model.media.size
        if size.width > 0 { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            ScreenRecordingPlayerView(playback: model.playback)
            if model.playback.isLoaded {
                Button(action: model.togglePlayback) {
                    Image(systemName: "play.fill").font(.system(size: 22)).foregroundStyle(.white)
                        .frame(width: 60, height: 60).background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L("recording.play"))
                .opacity(!model.isPlaying && stageHover ? 1 : 0)
            } else if !model.playback.isBusy, model.state == .preview {
                VStack(spacing: 10) {
                    Button(L("recording.reloadPreview"), action: model.reloadPreviewPlayback)
                    Button(L("recording.revealOriginal"), action: model.revealOriginal)
                }
                .buttonStyle(ModelActionStyle()).padding(.top, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 180)
        .background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle()).onTapGesture { if model.playback.isLoaded { model.togglePlayback() } }
        .onHover { stageHover = $0 }
        .padding(.horizontal, 16)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(L("recording.play"))
            .disabled(!model.playback.isLoaded || model.playback.isBusy)
            .modifier(EditorShortcutHint(key: model.state == .preview && model.playback.isLoaded &&
                !model.playback.isBusy ? "Space" : nil,
                                         visible: showsShortcutHints))
            Text(ScreenRecordingLayout.preciseTime(model.currentTime)).font(.system(size: 12.5, design: .monospaced))
                + Text(" / " + ScreenRecordingLayout.preciseTime(model.duration))
                .font(.system(size: 12.5, design: .monospaced)).foregroundColor(StudioTheme.textTertiary)
            Spacer()
            Button { showsSpeed.toggle() } label: {
                Label(ScreenRecordingEdit.rateTitle(model.edit.rate), systemImage: "speedometer")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .buttonStyle(ScreenRecordingPillStyle(active: model.edit.rate != 1))
            .help(L("recording.speed")).accessibilityLabel(L("recording.speed"))
            .accessibilityValue(ScreenRecordingEdit.rateTitle(model.edit.rate))
            .accessibilityIdentifier("recording.preview.speed")
            .disabled(model.state != .preview)
            .modifier(EditorShortcutHint(key: model.state == .preview ? "[ ]" : nil,
                                         visible: showsShortcutHints))
            .popover(isPresented: $showsSpeed, arrowEdge: .top) {
                ScreenRecordingSpeedMenu(model: model) { showsSpeed = false }
            }
            audioControl
        }
    }

    @ViewBuilder private var audioControl: some View {
        let tracks = model.edit.tracks
        if model.media.audio == .absent {
            Label(L("recording.silent"), systemImage: "speaker.slash").font(.system(size: 12))
                .foregroundStyle(StudioTheme.textTertiary).help(L("recording.noAudioTrack"))
        } else if !tracks.isEmpty {
            let gif = model.options.format == .gif
            let kept = model.edit.includedTracks.count
            Button { showsTracks.toggle() } label: {
                Label(gif ? L("recording.gifSilent") : L("recording.tracksButton", kept, tracks.count),
                      systemImage: gif || kept == 0 ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 12))
            }
            .buttonStyle(ScreenRecordingPillStyle(active: !gif && kept < tracks.count))
            .disabled(gif || model.state != .preview)
            .accessibilityIdentifier("recording.preview.tracks")
            .popover(isPresented: $showsTracks, arrowEdge: .top) { ScreenRecordingTrackMenu(model: model) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "trash")
                    .frame(width: 30, height: SettingsControlMetrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(StudioTheme.danger)
            .help(L("recording.discard"))
            .accessibilityLabel(L("recording.discard"))
            .accessibilityIdentifier("recording.preview.discard")
            .modifier(EditorShortcutHint(key: model.state == .preview ? "esc" : nil,
                                         visible: showsShortcutHints))
            Divider().frame(height: 20)
            Picker(L("recording.format"), selection: $model.options.format) {
                Text("MP4").tag(ScreenRecordingFormat.mp4); Text("GIF").tag(ScreenRecordingFormat.gif)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 108).disabled(model.state == .exporting)
            VStack(alignment: .leading, spacing: 2) {
                Text(outputSpecs).font(.system(size: 12))
                Text(model.exportSummary).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: 2)
            if model.state == .exporting {
                ScreenRecordingExportProgress(progress: model.progress, format: model.options.format)
                    .frame(width: 230, height: 30)
                Button(L("recording.cancelExport"), action: model.cancelExport)
                    .accessibilityIdentifier("recording.preview.cancelExport")
            } else {
                destinationMenu
                Button { model.export(copy: true) } label: { Label(L("recording.copy"), systemImage: "doc.on.doc") }
                    .disabled(!model.canExport)
                    .accessibilityIdentifier("recording.preview.copy")
                Button { model.export() } label: {
                    Label(L("recording.saveFormat", model.options.format.rawValue.uppercased()),
                          systemImage: "checkmark")
                }
                .buttonStyle(ModelActionStyle(primary: true)).disabled(!model.canExport)
                .modifier(EditorShortcutHint(key: model.canExport ? "⌘S" : nil, visible: showsShortcutHints))
                .help(model.gifTooLong ? L("recording.gifTooLong") : "")
                .accessibilityIdentifier("recording.preview.save")
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .buttonStyle(ModelActionStyle())
    }

    private var outputSpecs: String {
        let fps = model.options.captureFPS
        return "\(Int(model.previewOutputSize.width)) × \(Int(model.previewOutputSize.height)) · \(fps) FPS · " +
            L("recording.estimated", ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file))
    }

    private var destinationMenu: some View {
        let current = model.destinationDirectory.standardizedFileURL
        return Button { showsDestinations.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(L("recording.saveTo") + " " + Self.folderName(current)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .frame(maxWidth: 190)
        }
        .help(current.path)
        .accessibilityIdentifier("recording.preview.directory")
        .popover(isPresented: $showsDestinations, arrowEdge: .top) {
            ScreenRecordingDestinationMenu(model: model, current: current, chooseDirectory: chooseDirectory,
                                           saveAs: saveAs) { showsDestinations = false }
        }
    }

    static func folderName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
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
